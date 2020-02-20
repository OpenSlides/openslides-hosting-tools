#!/bin/bash

set -e

export PGDATA=/var/lib/postgresql/11/main
MARKER=/var/lib/postgresql/do-not-remove-this-file
BACKUP_DIR="/var/lib/postgresql/backup/"

# repmgr configuration through ENV
REPMGR_ENABLE_ARCHIVE="${REPMGR_WAL_ARCHIVE:-on}"
REPMGR_RECONNECT_ATTEMPTS="${REPMGR_RECONNECT_ATTEMPTS:-30}" # upstream default: 6
REPMGR_RECONNECT_INTERVAL="${REPMGR_RECONNECT_INTERVAL:-10}"

update_pgconf() {
  psql \
    -c "ALTER SYSTEM SET listen_addresses = '*';" \
    -c "ALTER SYSTEM SET archive_mode = on;" \
    -c "ALTER SYSTEM SET archive_command = '/bin/true';" \
    -c "ALTER SYSTEM SET wal_log_hints = on;" \
    -c "ALTER SYSTEM SET wal_keep_segments = 10;" \
    -c "ALTER SYSTEM SET shared_preload_libraries = 'repmgr';"
}

enable_wal_archiving() {
  mkdir -p "/var/lib/postgresql/wal-archive/"
  psql \
    -c "ALTER SYSTEM SET archive_mode = 'on';" \
    -c "ALTER SYSTEM SET archive_command =
        'gzip < %p > /var/lib/postgresql/wal-archive/%f'"
}

primary_node_setup() {
  # Temporarily change port of master node during setup
  sed -i -e '/^port/s/5432/5433/' \
    /etc/postgresql/11/main/postgresql.conf
  pg_ctlcluster 11 main start
  until pg_isready -p 5433; do
    echo "Waiting for Postgres cluster to become available..."
    sleep 3
  done
  update_pgconf
  [[ "$REPMGR_ENABLE_ARCHIVE" = "off" ]] || enable_wal_archiving
  pg_ctlcluster 11 main restart
  createuser -s repmgr && createdb repmgr -O repmgr
  repmgr -f /etc/repmgr.conf -p 5433 primary register
  repmgr -f /etc/repmgr.conf -p 5433 cluster show

  # create OpenSlides specific user and db
  createuser -s openslides && createdb openslides -O openslides

  # create settings table
  createdb instancecfg -O openslides
  psql -1 -d instancecfg \
    -c "CREATE TABLE markers (name text, configured bool DEFAULT false);" \
    -c "INSERT INTO markers VALUES('admin', false), ('user', false);" \
    -c "CREATE TABLE files (
      id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      filename VARCHAR NOT NULL,
      data VARCHAR NOT NULL,
      created TIMESTAMP DEFAULT now(),
      from_host VARCHAR);"

  # create mediafiles database; the schema is created by the media service
  createdb mediafiledata -O openslides

  pg_ctlcluster 11 main stop
  sed -i -e '/^port/s/5433/5432/' \
    /etc/postgresql/11/main/postgresql.conf
}

standby_node_setup() {
  # Remove cluster data dir, so it can be cloned into
  rm -r "$PGDATA" && mkdir "$PGDATA"
  # wait for master node
  until pg_isready -h "$REPMGR_PRIMARY"; do
    echo "Waiting for Postgres master server to become available..."
    sleep 3
  done
  repmgr -h "$REPMGR_PRIMARY" -U repmgr -d repmgr \
    -f /etc/repmgr.conf standby clone --fast-checkpoint
  pg_ctlcluster 11 main start
  until pg_isready; do
    echo "Waiting for Postgres cluster to become available..."
    sleep 3
  done
  pg_ctlcluster 11 main restart
  repmgr -f /etc/repmgr.conf standby register --force
  repmgr -f /etc/repmgr.conf cluster show || true
}

backup() {
  mkdir -p "$BACKUP_DIR"
  pg_basebackup -D - -Ft \
    --wal-method=fetch --checkpoint=fast \
    --write-recovery-conf \
    --label="Initial base backup (entrypoint)" |
  gzip > "${BACKUP_DIR}/backup-$(date '+%F-%H:%M:%S').tar.bz2"
}

echo "Configuring repmgr"
sed -e "s/<NODEID>/${REPMGR_NODE_ID}/" \
  -e "s/<RECONNECT_ATTEMPTS>/${REPMGR_RECONNECT_ATTEMPTS}/" \
  -e "s/<RECONNECT_INTERVAL>/${REPMGR_RECONNECT_INTERVAL}/" \
  /etc/repmgr.conf.in | tee /etc/repmgr.conf

# Update pg_hba.conf from image template
cp -fv /var/lib/postgresql/pg_hba.conf /etc/postgresql/11/main/pg_hba.conf

if [[ ! -f "$MARKER" ]]; then
  if [[ -z "$REPMGR_PRIMARY" ]]; then
    primary_node_setup
    # Create an initial basebackup
    echo "Creating base backup in ${BACKUP_DIR}..."
    backup
  else
    standby_node_setup
  fi
  echo "Successful repmgr setup as node id $REPMGR_NODE_ID" | tee "$MARKER"
fi

# Stop cluster, so it can be started by supervisord
pg_ctlcluster 11 main stop
