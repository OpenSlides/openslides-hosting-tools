#!/bin/bash

set -e
set -o pipefail

export PGDATA=/var/lib/postgresql/11/main
MARKER=/var/lib/postgresql/do-not-remove-this-file
BACKUP_DIR="/var/lib/postgresql/backup/"

# repmgr configuration through ENV
REPMGR_ENABLE_ARCHIVE="${REPMGR_WAL_ARCHIVE:-on}"
REPMGR_RECONNECT_ATTEMPTS="${REPMGR_RECONNECT_ATTEMPTS:-30}" # upstream default: 6
REPMGR_RECONNECT_INTERVAL="${REPMGR_RECONNECT_INTERVAL:-10}"

SSH_HOST_KEY="/var/lib/postgresql/.ssh/ssh_host_ed25519_key"
SSH_REPMGR_USER_KEY="/var/lib/postgresql/.ssh/id_ed25519"
SSH_PGPROXY_USER_KEY="/var/lib/postgresql/.ssh/id_ed25519_pgproxy"

SSH_CONFIG_FILES=(
  "${SSH_HOST_KEY}::{\"repmgr\"}"
  "${SSH_HOST_KEY}.pub::{\"repmgr\"}"
  "${SSH_PGPROXY_USER_KEY}:/var/lib/postgresql/.ssh/id_ed25519:{\"pgproxy\"}"
  "${SSH_PGPROXY_USER_KEY}.pub:/var/lib/postgresql/.ssh/id_ed25519.pub:{\"pgproxy\"}"
  "${SSH_REPMGR_USER_KEY}::{\"repmgr\"}"
  "${SSH_REPMGR_USER_KEY}.pub::{\"repmgr\"}"
  "/var/lib/postgresql/.ssh/authorized_keys::{\"repmgr\"}"
  "/var/lib/postgresql/.ssh/known_hosts::{\"repmgr\", \"pgproxy\"}"
)

primary_ssh_setup() {
  # Generate SSH keys
  local PGNODES="pgnode1,pgnode2,pgnode3"
  ssh-keygen -t ed25519 -N '' -f "$SSH_HOST_KEY"
  ssh-keygen -t ed25519 -N '' -f "$SSH_REPMGR_USER_KEY" -C "repmgr node key"
  ssh-keygen -t ed25519 -N '' -f "$SSH_PGPROXY_USER_KEY" \
    -C "Pgbouncer access key"
  # Setup access
  cp "${SSH_REPMGR_USER_KEY}.pub" /var/lib/postgresql/.ssh/authorized_keys
  printf 'command="/usr/local/bin/current-primary" %s\n' \
    "$(cat "${SSH_PGPROXY_USER_KEY}.pub")" \
    >> /var/lib/postgresql/.ssh/authorized_keys
  printf '%s %s\n' "${PGNODES}" "$(cat "${SSH_HOST_KEY}.pub")" \
    > /var/lib/postgresql/.ssh/known_hosts
}

insert_config_into_db() {
  local real_filename target_filename access b64
  real_filename="$1"
  target_filename="$2"
  access="$3"
  b64="$(base64 < "$real_filename")"
  psql -v ON_ERROR_STOP=1 -1 -d instancecfg \
    -c "INSERT INTO dbcfg (filename, data, from_host, access)
      VALUES('${target_filename}',
        decode('$b64', 'base64'),
        '$(hostname)', '${access}')"
}

update_pgconf() {
  psql -v ON_ERROR_STOP=1 \
    -c "ALTER SYSTEM SET listen_addresses = '*';" \
    -c "ALTER SYSTEM SET archive_mode = on;" \
    -c "ALTER SYSTEM SET archive_command = '/bin/true';" \
    -c "ALTER SYSTEM SET wal_log_hints = on;" \
    -c "ALTER SYSTEM SET wal_keep_segments = 10;" \
    -c "ALTER SYSTEM SET shared_preload_libraries = 'repmgr';"
}

enable_wal_archiving() {
  psql -v ON_ERROR_STOP=1 \
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
  createuser openslides && createdb openslides -O openslides

  # create mediafiles database; the schema is created by the media service
  createdb mediafiledata -O openslides

  # create OpenSlides settings table
  createdb instancecfg
  psql -v ON_ERROR_STOP=1 -d instancecfg <<< "
    BEGIN;
    CREATE TABLE markers (name text, configured bool DEFAULT false);
    INSERT INTO markers VALUES('admin', false), ('user', false);
    --
    CREATE TABLE files (
      id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      filename VARCHAR NOT NULL,
      data VARCHAR NOT NULL,
      created TIMESTAMP DEFAULT now(),
      from_host VARCHAR);
    --
    GRANT ALL ON markers TO openslides;
    GRANT ALL ON files TO openslides;
    --
    CREATE TABLE dbcfg (
      id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      filename VARCHAR NOT NULL,
      data BYTEA NOT NULL,
      created TIMESTAMP DEFAULT now(),
      from_host VARCHAR,
      access VARCHAR []);
    ALTER TABLE dbcfg ENABLE ROW LEVEL SECURITY;
    COMMENT ON TABLE dbcfg IS 'This table uses row security policies';
    CREATE ROLE pgproxy WITH LOGIN;
    GRANT SELECT ON dbcfg TO pgproxy;
    CREATE POLICY dbcfg_read_policy
      ON dbcfg USING (CURRENT_USER = ANY (access) OR access = '{\"public\"}');
    --
    COMMIT;
    "

  # Insert SSH files
  for i in "${SSH_CONFIG_FILES[@]}"; do
    IFS=: read -r item target_filename access <<< "$i"
    [[ -n "$target_filename" ]] || target_filename="$item"
    echo "Inserting ${item}→${target_filename} into database..."
    insert_config_into_db "$item" "$target_filename" "$access"
  done

  # delete pgproxy key
  rm -f "${SSH_PGPROXY_USER_KEY}" "${SSH_PGPROXY_USER_KEY}.pub"

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

  ( # Fetch SSH files from database
    umask 077
    psql -qAt instancecfg <<< "
      SELECT DISTINCT ON (filename, access) filename FROM dbcfg
      WHERE 'repmgr' = ANY (access)
      ORDER BY filename, access, id DESC;" |
    while read target_filename; do
      echo "Fetching ${target_filename} from database..."
      psql -d instancecfg -qtA <<< "
        SELECT DISTINCT ON (filename, access) data from dbcfg
          WHERE filename = '${target_filename}'
          AND   'repmgr' = ANY (access)
          ORDER BY filename, access, id DESC;
        " | xxd -r -p > "${target_filename}"
    done
  )
}

backup() {
  mkdir -p "$BACKUP_DIR"
  pg_basebackup -D - -Ft \
    --wal-method=fetch --checkpoint=fast \
    --write-recovery-conf \
    --label="Initial base backup (entrypoint)" |
  gzip > "${BACKUP_DIR}/backup-$(date '+%F-%H:%M:%S').tar.bz2"
}

mkdir -p "/var/lib/postgresql/wal-archive/"

echo "Configuring repmgr"
sed -e "s/<NODEID>/${REPMGR_NODE_ID}/" \
  -e "s/<RECONNECT_ATTEMPTS>/${REPMGR_RECONNECT_ATTEMPTS}/" \
  -e "s/<RECONNECT_INTERVAL>/${REPMGR_RECONNECT_INTERVAL}/" \
  /etc/repmgr.conf.in | tee /etc/repmgr.conf

# Update pg_hba.conf from image template
cp -fv /var/lib/postgresql/pg_hba.conf /etc/postgresql/11/main/pg_hba.conf

if [[ ! -f "$MARKER" ]]; then
  if [[ -z "$REPMGR_PRIMARY" ]]; then
    primary_ssh_setup
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
