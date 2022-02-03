#!/bin/bash

# Manage dockerized OpenSlides instances
#
# -------------------------------------------------------------------
# Copyright (C) 2019,2021 by Intevation GmbH
# Author(s):
# Gernot Schulz <gernot@intevation.de>
# Adrian Richter <adrian@intevation.de>
#
# This program is distributed under the MIT license, as described
# in the LICENSE file included with the distribution.
# SPDX-License-Identifier: MIT
# -------------------------------------------------------------------

set -eu
set -o noclobber
set -o pipefail

# Defaults (override in /etc/osinstancectl)
INSTANCES="/srv/openslides/os4-instances"
COMPOSE_TEMPLATE=
CONFIG_YML_TEMPLATE=
HOOKS_DIR=
MANAGEMENT_TOOL_BINDIR="/usr/local/lib/openslides-manage/versions"
MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/latest"

# Legacy instances path
OS3_INSTANCES="/srv/openslides/docker-instances"

ME=$(basename -s .sh "${BASH_SOURCE[0]}")
CONFIG="/etc/os4instancectl"
MARKER=".osinstancectl-marker"
PROJECT_NAME=
PROJECT_DIR=
PROJECT_STACK_NAME=
PORT=
DEPLOYMENT_MODE=
MODE=
DOCKER_IMAGE_TAG_OPENSLIDES=
ACCOUNTS=
AUTOSCALE_ACCOUNTS_OVER=
AUTOSCALE_RESET_ACCOUNTS_OVER=
OPT_LONGLIST=
OPT_SERVICES=
OPT_SECRETS=
OPT_METADATA=
OPT_METADATA_SEARCH=
OPT_JSON=
OPT_ADD_ACCOUNT=1
OPT_LOCALONLY=
OPT_FORCE=
OPT_ALLOW_DOWNSCALE=
OPT_RESET=
OPT_DRY_RUN=
OPT_FAST=
OPT_PATIENT=
OPT_USE_PARALLEL="${OPT_USE_PARALLEL:-1}"
OPT_MANAGEMENT_TOOL=
FILTER_STATE=
FILTER_VERSION=
CLONE_FROM=
ADMIN_SECRETS_FILE="superadmin"
USER_SECRETS_FILE="user.yml"
DB_SECRETS_FILE="postgres_password"
OPENSLIDES_USER_FIRSTNAME=
OPENSLIDES_USER_LASTNAME=
OPENSLIDES_USER_EMAIL=
OPENSLIDES_USER_PASSWORD=
OPT_PRECISE_PROJECT_NAME=
CURL_OPTS=(--max-time 1 --retry 2 --retry-delay 1 --retry-max-time 3)

# Color and formatting settings
OPT_COLOR=auto
NCOLORS=
COL_NORMAL=""
COL_RED=""
COL_YELLOW=""
COL_GREEN=""
BULLET='●'
SYM_NORMAL="OK"
SYM_ERROR="XX"
SYM_UNKNOWN="??"
SYM_STOPPED="__"
JQ="jq --monochrome-output"

enable_color() {
  NCOLORS=$(tput colors) # no. of colors
  if [[ -n "$NCOLORS" ]] && [[ "$NCOLORS" -ge 8 ]]; then
    COL_NORMAL="$(tput sgr0)"
    COL_RED="$(tput setaf 1)"
    COL_YELLOW="$(tput setaf 3)"
    COL_GREEN="$(tput setaf 2)"
    COL_GRAY="$(tput bold; tput setaf 0)"
    JQ="jq --color-output"
  fi
}

usage() {
cat <<EOF
Usage: $ME [options] <action> <instance|pattern>

Manage OpenSlides Docker instances.

Actions:
  ls                   List instances and their status.  <pattern> is
                       a grep ERE search pattern in this case.  For details on
                       the output format, see below.
  add                  Add a new instance for the given domain (requires FQDN)
  rm                   Remove <instance> (requires FQDN)
  start                Start, i.e., (re)deploy an existing instance
  stop                 Stop a running instance
  update               Update OpenSlides services to a new images
  erase                Execute the mid-erase hook without otherwise removing
                       the instance.
  autoscale            Scale relevant services of an instance based on it's
                       ACCOUNTS metadatum (adjust values in CONFIG file)

Options:
  -d,
  --project-dir=DIR    Directly specify the project directory
  --compose-template=FILE  Specify a YAML template
  --config-template=FILE   Specify a .env template
  --force              Disable various safety checks
  --color=WHEN         Enable/disable color output.  WHEN is never, always, or
                       auto.

  for ls:
    -a, --all          Equivalent to --long --secrets --metadata --services
    -l, --long         Include more information in extended listing format
    -s, --secrets      Include sensitive information such as login credentials
    -m, --metadata     Include metadata in instance list
    --services         Include list of services in instance list
    -n, --online       Show only online instances
    -f, --offline      Show only stopped instances
    -e, --error        Show only running but unreachable instances
    -M,
    --search-metadata  Include metadata
    --fast             Include less information to increase listing speed
    --patient          Increase timeouts
    --version=REGEXP   Filter results based on the version reported by
                       \`$ME ls\` (not --long; implies --online).
    -j, --json         Enable JSON output format

  for add & update:
    -t, --tag=TAG      Specify the default image tag for all OpenSlides
                       components (defaults.tag).
    -O, --management-tool=[PATH|NAME|-]
                       Specify the 'openslides' executable to use.  The program
                       must be available in the management tool's versions
                       directory [${MANAGEMENT_TOOL_BINDIR}/].
                       If only a file NAME is given, it is assumed to be
                       relative to that directory.
                       The special string "-" indicates that the latest version
                       is to be followed.
    --local-only       Create an instance without setting up HAProxy and Let's
                       Encrypt certificates.  Such an instance is only
                       accessible on localhost, e.g., http://127.0.0.1:61000.
    --no-add-account   Do not add an additional, customized local admin account
    --clone-from       Create the new instance based on the specified existing
                       instance

  for autoscale:
    --allow-downscale  Without this option services will only be scaled upward to
                       to prevent possibly undoing manual scaling adjusmtents
    --reset            Reset all scaling back to normal
    --accounts=NUM     Specify the number of acoounts to scale for overriding
                       read from metadata.txt
    --dry-run          Print out actions instead of actually performing them

The ls output:

  The columnar output lists each instance's status, name, version(s) and
  an optional comment.

  Colored status indicators:
    green              The instance appears to be fully functional
    red                The instance is running but is unreachable
    yellow             The instance's status can not be determined
    gray               The instance has been stopped

  Version information in ls mode:

    The listed version is the containers' Docker image tag currently in use.
    Normally, this is a single tag.  In case there is more than one tag in use,
    the display format is extended to include more detail.  It lists each tag
    with the number of containers running this tag, separated by slashes, as
    well as a final sum of the number of different registries and tags in
    square brackets, e.g., "[1:2]".
EOF
}

fatal() {
    echo 1>&2 "${COL_RED}ERROR${COL_NORMAL}: $*"
    exit 23
}

warn() {
    echo 1>&2 "${COL_RED}WARN${COL_NORMAL}: $*"
}

info() {
    echo 1>&2 "${COL_GREEN}INFO${COL_NORMAL}: $*"
}

check_for_dependency () {
    [[ -n "$1" ]] || return 0
    command -v "$1" > /dev/null || { fatal "Dependency not found: $1"; }
}

arg_check() {
  [[ -d "$INSTANCES" ]] || { fatal "$INSTANCES not found!"; }
  [[ -n "$PROJECT_NAME" ]] || {
    fatal "Please specify a project name"; return 2;
  }
  case "$MODE" in
    "start" | "stop" | "remove" | "erase" | "update" | "autoscale")
      [[ -d "$PROJECT_DIR" ]] || {
        fatal "Instance '${PROJECT_NAME}' not found."
      }
      [[ -f "${DCCONFIG}" ]] || {
        fatal "Not a ${DEPLOYMENT_MODE} instance."
      }
      ;;
    "clone")
      [[ -d "$CLONE_FROM_DIR" ]] || {
        fatal "$CLONE_FROM_DIR does not exist."
      }
      ;;
    "create")
      [[ ! -d "$PROJECT_DIR" ]] || {
        fatal "Instance '${PROJECT_NAME}' already exists."
      }
      [[ ! -d "${OS3_INSTANCES}/${PROJECT_NAME}" ]] || {
        fatal "Instance '${PROJECT_NAME}' already exists as an OpenSlides 3 instance."
      }
      ;;
  esac
}

marker_check() {
  [[ -f "${1}/${MARKER}" ]] || {
    fatal "The instance was not created with $ME."
    return 1
  }
}

hash_management_tool() {
  # Return the SHA256 hash of the selected "openslides" tool.  For lack of
  # proper versioning, the has is used to track compatibility with individual
  # instances by adding it to each config.yml.
  sha256sum "$MANAGEMENT_TOOL" 2>/dev/null | awk '{ print $1 }' ||
    fatal "$MANAGEMENT_TOOL not found."
}

select_management_tool() {
  # Read the required management tool version from the instance's config file
  # or use the version provided on the command line.
  if [[ -n "$OPT_MANAGEMENT_TOOL" ]]; then
    # The given argument is the special string "-", indicating that the latest
    # version should be followed
    if [[ "$OPT_MANAGEMENT_TOOL" = '-' ]]; then
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/latest"
    elif [[ "$OPT_MANAGEMENT_TOOL" =~ \/ ]]; then
      # The given argument is a path
      MANAGEMENT_TOOL=$(realpath "$OPT_MANAGEMENT_TOOL")
    else
      # The given argument is only a filename; prepend path here
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/${OPT_MANAGEMENT_TOOL}"
    fi
  # Reading tool version from instance configuration
  elif MANAGEMENT_TOOL_HASH=$(value_from_config_yml "$PROJECT_DIR" '.managementToolHash'); then
    # Version is set to simply follow latest
    if [[ "$MANAGEMENT_TOOL_HASH" = '-' ]]; then
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/latest"
    # Version is configured to a specific hash
    else
      MANAGEMENT_TOOL="${MANAGEMENT_TOOL_BINDIR}/${MANAGEMENT_TOOL_HASH}"
    fi
  else # Fall back to default
    MANAGEMENT_TOOL="${MANAGEMENT_TOOL}"
  fi
  MANAGEMENT_TOOL_HASH=$(hash_management_tool)
  if [[ -x "$MANAGEMENT_TOOL" ]]; then
    info "Using 'openslides' tool at $MANAGEMENT_TOOL"
  else
    fatal "$MANAGEMENT_TOOL not found."
  fi
}

next_free_port() {
  # Select new port
  #
  # This parses existing instances' YAML files to discover used ports and to
  # select the next one.  Other methods may be more suitable and robust but
  # have other downsides.  For example, `docker-compose port client 80` is
  # only available for running services.
  local HIGHEST_PORT_IN_USE
  local PORT
  HIGHEST_PORT_IN_USE=$(
    {
      # OS3 instance ports
      find "${OS3_INSTANCES}" -type f -name ".env" -print0 |
      xargs -0 --no-run-if-empty grep -h "EXTERNAL_HTTP_PORT" |
      cut -d= -f2 | tr -d \"\'
      # OS4 instance ports
      find "${INSTANCES}" -type f -name "config.yml" -print0 |
      xargs -0 --no-run-if-empty yq --no-doc eval '.port'
    } | sort -rn | head -1
  )
  [[ -n "$HIGHEST_PORT_IN_USE" ]] || HIGHEST_PORT_IN_USE=61000
  PORT=$((HIGHEST_PORT_IN_USE + 1))

  # Check if port is actually free
  #  try to find the next free port (this situation can occur if there are test
  #  instances outside of the regular instances directory)
  n=0
  while ! ss -tnHl | gawk -v port="$PORT" '$4 ~ port { exit 2 }'; do
    [[ $n -le 25 ]] || { fatal "Could not find free port"; }
    ((PORT+=1))
    [[ $PORT -le 65535 ]] || { fatal "Ran out of ports"; }
    ((n+=1))
  done
  echo "$PORT"
}

value_from_config_yml() {
  local instance target result
  instance="$1"
  target="$2"
  result=null
  if [[ -f "${instance}/config.yml" ]]; then
    result=$(yq eval $target "${instance}/config.yml")
  fi
  if [[ "$result" == "null" ]]; then
    if [[ -f "${CONFIG_YML_TEMPLATE}" ]]; then
      result=$(yq eval $target "${CONFIG_YML_TEMPLATE}")
    fi
  fi
  [[ "$result" != "null" ]] || return 1
  echo "$result"
}

update_config_yml() {
  local file=$1
  local expr=$2
  [[ -f "$file" ]] || touch "$file"
  yq eval -i "$expr" "$file"
}

recreate_compose_yml() {
  local template= config=
  [[ -z "$COMPOSE_TEMPLATE" ]] ||
    template="--template=${COMPOSE_TEMPLATE}"
  [[ -z "$CONFIG_YML_TEMPLATE" ]] ||
    config="--config=${CONFIG_YML_TEMPLATE}"
  "${MANAGEMENT_TOOL}" config $template $config \
    --config="${PROJECT_DIR}/config.yml" "${PROJECT_DIR}"
}

openslides_connect_opts() {
  local dir=${1-$PROJECT_DIR}
  local port=$(value_from_config_yml "$dir" '.port')
  local secret="${dir}/secrets/manage_auth_password"
  echo "-a 127.0.0.1:${port} --password-file $secret --no-ssl"
}

gen_pw() {
  local len="${1:-15}"
  read -r -n "$len" PW < <(LC_ALL=C tr -dc "[:alnum:]" < /dev/urandom)
  echo "$PW"
}

update_config_instance_specifics() {
  # Configure instance specifics in config.yml
  touch "${PROJECT_DIR}/config.yml"
  update_config_yml "${PROJECT_DIR}/config.yml" ".port = $PORT"

  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".stackName = \"$PROJECT_STACK_NAME\""
  if [[ -n "$DOCKER_IMAGE_TAG_OPENSLIDES" ]]; then
    update_config_yml "${PROJECT_DIR}/config.yml" ".defaults.tag = \"$DOCKER_IMAGE_TAG_OPENSLIDES\""
  fi
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".services.proxy.environment.ALLOWED_HOSTS = \"127.0.0.1 $PROJECT_NAME\""
}

update_config_services_db_connect_params() {
  # Write DB-connection credentials to config
  # for datastore
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.DATASTORE_DATABASE_NAME = \"${PROJECT_NAME}\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.DATASTORE_DATABASE_USER = \"${PROJECT_NAME}_user\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.DATASTORE_DATABASE_PASSWORD_FILE = \"/run/secrets/postgres_password\""
  # for media
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.MEDIA_DATABASE_NAME = \"${PROJECT_NAME}\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.MEDIA_DATABASE_USER = \"${PROJECT_NAME}_user\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.MEDIA_DATABASE_PASSWORD_FILE = \"/run/secrets/postgres_password\""
  # for vote
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.VOTE_DATABASE_NAME = \"${PROJECT_NAME}\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.VOTE_DATABASE_USER = \"${PROJECT_NAME}_user\""
  update_config_yml "${PROJECT_DIR}/config.yml" \
    ".defaultEnvironment.VOTE_DATABASE_PASSWORD_FILE = \"/run/secrets/postgres_password\""
}

create_admin_secrets_file() {
  echo "Generating superadmin password..."
  local admin_secret="${PROJECT_DIR}/secrets/${ADMIN_SECRETS_FILE}"
  rm "$admin_secret"
  touch "$admin_secret"
  chmod 600 "$admin_secret"
  gen_pw | tr -d '\n' >> "$admin_secret"
}

query_user_account_name() {
  if [[ -n "$OPT_ADD_ACCOUNT" ]]; then
    echo "Create local admin account for:"
    while [[ -z "$OPENSLIDES_USER_FIRSTNAME" ]] || \
          [[ -z "$OPENSLIDES_USER_LASTNAME" ]]
    do
      read -rp "First & last name: " \
        OPENSLIDES_USER_FIRSTNAME OPENSLIDES_USER_LASTNAME
      read -rp "Email (optional): " OPENSLIDES_USER_EMAIL
    done
  fi
}

create_user_secrets_file() {
  if [[ -n "$OPT_ADD_ACCOUNT" ]]; then
    local first_name
    local last_name
    local email # optional
    local PW
    echo "Generating user credentials..."
    first_name=$1
    last_name=$2
    email=$3
    PW=$(gen_pw)
    touch "${PROJECT_DIR}/secrets/${USER_SECRETS_FILE}.setup"
    chmod 600 "${PROJECT_DIR}/secrets/${USER_SECRETS_FILE}.setup"
    cat << EOF >> "${PROJECT_DIR}/secrets/${USER_SECRETS_FILE}.setup"
---
first_name: "$first_name"
last_name: "$last_name"
username: "$first_name $last_name"
email: "$email"
default_password: "$PW"
is_active: true
organization_management_level: can_manage_organization
committee__management_level:
  1: can_manage
group__ids:
  1: [1, 2]
EOF
  fi
}

create_instance_dir() {
  local template= config=
  [[ -z "$COMPOSE_TEMPLATE" ]] ||
    template="--template=${COMPOSE_TEMPLATE}"
  [[ -z "$CONFIG_YML_TEMPLATE" ]] ||
    config="--config=${CONFIG_YML_TEMPLATE}"

  "${MANAGEMENT_TOOL}" setup $template $config "$PROJECT_DIR" ||
    fatal "Error during \`"${MANAGEMENT_TOOL}" setup\`"
  touch "${PROJECT_DIR}/${MARKER}"

  # Restrict access to secrets b/c the management tool sets very open access
  # permissions
  chmod -R 600 "${PROJECT_DIR}/secrets/"
  chmod 700 "${PROJECT_DIR}/secrets"

  # Note which version of the openslides tool is compatible with the instance,
  # unless special string "-" is given
  if [[ "$OPT_MANAGEMENT_TOOL" = '-' ]]; then
    update_config_yml "${PROJECT_DIR}/config.yml" ".managementToolHash = \"$OPT_MANAGEMENT_TOOL\""
  else
    update_config_yml "${PROJECT_DIR}/config.yml" ".managementToolHash = \"$MANAGEMENT_TOOL_HASH\""
  fi

  # Due to a bug in "openslides", the db-data directory is created even if the
  # stack's Postgres service that would require it is disabled.
  # XXX: This is going to be fixed in the near future.  For now, remain
  # backwards-compatible.
  if [[ -d "${PROJECT_DIR}/db-data" ]] && [[ $(value_from_config_yml "$PROJECT_DIR" '.disablePostgres') == "true" ]]
  then
    rmdir "${PROJECT_DIR}/db-data"
  fi
}

add_to_haproxy_cfg() {
  [[ -z "$OPT_LOCALONLY" ]] || return 0
  cp -f /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.osbak &&
    gawk -v target="${PROJECT_NAME}" -v port="${PORT}" '
    BEGIN {
      begin_block = "-----BEGIN AUTOMATIC OPENSLIDES CONFIG-----"
      end_block   = "-----END AUTOMATIC OPENSLIDES CONFIG-----"
      use_server_tmpl = "\tuse-server %s if { hdr_reg(Host) -i ^%s$ }"
      server_tmpl = "\tserver     %s 127.0.0.1:%d  weight 0 check"
    }
    $0 ~ begin_block { b = 1 }
    $0 ~ end_block   { e = 1 }
    !e
    b && e {
      printf(use_server_tmpl "\n", target, target)
      printf(server_tmpl "\n", target, port)
      print
      e = 0
    }
  ' /etc/haproxy/haproxy.cfg.osbak >| /etc/haproxy/haproxy.cfg &&
    systemctl reload haproxy
}

rm_from_haproxy_cfg() {
  cp -f /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.osbak &&
  gawk -v target="${PROJECT_NAME}" -v port="${PORT}" '
    BEGIN {
      begin_block = "-----BEGIN AUTOMATIC OPENSLIDES CONFIG-----"
      end_block   = "-----END AUTOMATIC OPENSLIDES CONFIG-----"
    }
    $0 ~ begin_block { b = 1 }
    $0 ~ end_block   { e = 1 }
    b && !e && $2 == target { next }
    1
  ' /etc/haproxy/haproxy.cfg.osbak >| /etc/haproxy/haproxy.cfg &&
    systemctl reload haproxy
}

remove() {
  local PROJECT_NAME="$1"
  [[ -d "$PROJECT_DIR" ]] || {
    fatal "$PROJECT_DIR does not exist."
  }
  echo "Stopping and removing containers..."
  instance_erase
  echo "Removing instance repo dir..."
  rm -rf "${PROJECT_DIR}"
  echo "remove HAProxy config..."
  rm_from_haproxy_cfg
  echo "Done."
}

ping_instance_simple() {
  # Check if the instance's reverse proxy is listening
  #
  # This is used as an indicator as to whether the instance is supposed to be
  # running or not.  The reason for this check is that it is fast and that the
  # reverse proxy container rarely fails itself, so it is always running when
  # an instance has been started.  Errors usually happen in the backend
  # container which is checked with instance_health_status.
  nc -z 127.0.0.1 "$1" || return 1
}

instance_health_status() {
  # Check instance's health through its provided HTTP resources
  #
  # backend
  LC_ALL=C curl -s "${CURL_OPTS[@]}" "http://127.0.0.1:${1}/system/action/health" |
    jq -r '.status' 2>/dev/null | grep -q 'running'
}

instance_has_services_running() {
  # Check if the instance has been deployed.
  #
  # This is used as an indicator as to whether the instance is *supposed* to be
  # running or not.
  local instance="$1"
  case "$DEPLOYMENT_MODE" in
    "stack")
      docker stack ls --format '{{ .Name }}' | grep -qw "^$instance\$" || return 1
      ;;
  esac
}

currently_running_version() {
  # Retrieve the OpenSlides image tags actually in use.
  case "$DEPLOYMENT_MODE" in
    "stack")
      docker stack services --format '{{ .Image }}' "${PROJECT_STACK_NAME}" |
      gawk -F: '# Skip expected non-OpenSlides images
        $1 == "redis" && $2 == "latest" { next }
        1
        '
      ;;
  esac |
  gawk -F: '
    {
      # Extract only the registry address from the image name (remove the
      # last element)
      sub(/\/[^\/]+$/, "", $1)
      reg[$1]++
      img[$2]++
    }
    END {
      # List image tags
      n = asorti(img, sorted, "@val_num_desc")
      for (i = 1; i <= n; i++) {
        if (n == 1) {
          printf("%s", sorted[i])
        } else {
          # If more than one image tag is in use, list them all with a count
          printf("%s(%d)", sorted[i], img[sorted[i]])
          if (i < length(img)) printf("/")
        }
      }
      # Add number of registries and tags if there are more than 1
      if (length(reg) > 1 || n > 1) printf(" [%d:%d]", length(reg), n)
    }
  '
}

highlight_match() {
  # Highlight search term match in string
  # By default, the PROJECT_NAME is matched but a custom sed-compatible search
  # term can be given as an optional second argument.

  # Return string as is if colors are disabled.
  if [[ -z "$NCOLORS" ]]; then
    echo "$1"
    return 0
  fi

  local string filter
  string=$1
  filter=${2:-PROJECT_NAME}
  sed -e "s/${filter}/$(tput smso)&$(tput rmso)/g" <<< "$string"
}

treefmt() {
  # Tree formatting function, for ls_instance()

  # Initialize treefmt first, if necessary
  if [[ -z "${treefmt_var_initialized:-}" ]]; then
    treefmt_var_initialized=1
    treefmt_var_default_tree_drawing_char=" "
    treefmt_var_default_tree_paddding_char=" "
    treefmt_var_draw_cont="├"
    treefmt_var_draw_close="└"
    treefmt_var_draw_body="┆"
    treefmt_var_padding=2
    treefmt_var_base_indent="   "
    treefmt_var_indentation_steps=$((treefmt_var_padding + 1)) # 1 is length of $tree_drawing_char
    treefmt_var_drawing_detail="${OPT_TREEFMT_DRAWING_DETAIL:-1}"
    treefmt reset

    treefmt_indentation() {
      local higher_lvl=$((lvl - 1))
      if [[ ${treefmt_var_drawing_detail} -eq 1 ]]; then
        for node_level in $(seq 1 "$higher_lvl"); do
          local tree_drawing_char=$treefmt_var_default_tree_drawing_char
          # Draw branch if there will be more nodes of the same level
          if [[ ${treefmt_var_node_count_per_lvl[$node_level]:-0} -gt 0 ]]; then
            tree_drawing_char="│"
          fi
          # But do not draw the branch if the parent node was the last of this
          # particular branch, i.e., is listed as a breaking node
          if echo "${treefmt_var_breaking_nodes[$node_level]:-}" |
              grep -qw "${last_node_in_lvl[$node_level]}"; then
            tree_drawing_char=$treefmt_var_default_tree_drawing_char
          fi
          printf "%s%s%${treefmt_var_padding}s" \
            "$indent" "$tree_drawing_char" "$treefmt_var_default_tree_paddding_char"
        done
      else
        # fast mode: simply print spaces for indentation
        [[ $higher_lvl -lt 1 ]] || printf "%$((higher_lvl * treefmt_var_indentation_steps))s" " "
      fi
    }

    treefmt_format() {
      for i in $(seq $treefmt_var_n); do
        local drawing_char=$treefmt_var_draw_close
        local lvl=${treefmt_var_level_array[$i]}
        # +1 for space after colon:
        local align=$((treefmt_var_max_align - lvl * treefmt_var_indentation_steps + 1))
        local indent=
        case "${treefmt_var_type_array[$i]}" in
          node)
            if [[ ${treefmt_var_drawing_detail} -eq 1 ]]; then
              local next_node=$((i+1))
              local next_node_level
              local last_node_in_lvl[$lvl]=$i
              next_node_level=${treefmt_var_level_array[$next_node]:-0}
              treefmt_var_node_count_per_lvl[$lvl]=$((treefmt_var_node_count_per_lvl[$lvl] - 1))
              if [[ "$next_node_level" -lt "$lvl" ]]; then
                # if the next node is of a higher level, this node must be;
                # closed.  any other nodes of the same level must be part of
                # a new subtree.
                drawing_char=$treefmt_var_draw_close
              elif echo "${treefmt_var_breaking_nodes[$lvl]:-}" | grep -qw "$i" ; then
                # if the current node has been recorded as the last node of
                # a certain level before a break.  This means there may be more
                # nodes of this level but the tree is broken up by higher-level
                # nodes in between.
                drawing_char=$treefmt_var_draw_close
              elif [[ "${treefmt_var_node_count_per_lvl[$lvl]}" -ge 1 ]]; then
                # if there are more nodes of the same level, draw continuation character
                drawing_char=$treefmt_var_draw_cont
              fi
              indent="${treefmt_var_base_indent}$(treefmt_indentation)"
            else
              drawing_char=$treefmt_var_draw_cont
              indent="${treefmt_var_base_indent}$(treefmt_indentation)"
            fi
            # If the node has a value, add a colon to the node key/header
            # local colon=
            if [[ -n "${treefmt_var_content_array[$i]}" ]]; then
              colon=:
            else
              colon=
            fi
            printf "%s%s%s%-${align}s %s\n" \
              "$indent" \
              "$drawing_char" \
              "$treefmt_var_default_tree_paddding_char" \
              "${header_array[$i]}${colon}" \
              "${treefmt_var_content_array[$i]}"
            ;;
          body)
            drawing_char="$treefmt_var_draw_body"
            indent="${treefmt_var_base_indent}$(treefmt_indentation)"
            printf "%s\n" "${treefmt_var_content_array[$i]}" | sed "s/^/$indent$drawing_char /"
            ;;
        esac
      done
    }
  fi

  case $1 in
    reset)
      treefmt_var_type_array=()
      treefmt_var_level_array=()
      treefmt_var_node_count_per_lvl=()
      treefmt_var_content_array=()
      treefmt_var_n=0
      treefmt_var_node_level=1
      treefmt_var_max_lvl=$treefmt_var_node_level
      treefmt_var_max_align=0
      declare -A treefmt_var_last_node_per_lvl=()
      declare -A treefmt_var_breaking_nodes=()
      ;;
    node)
      [[ -n $2 ]] || fatal "ProgrammingError: treefmt node name must not be empty"
      treefmt_var_n=$((treefmt_var_n + 1))
      treefmt_var_level_array[$treefmt_var_n]=$treefmt_var_node_level
      treefmt_var_node_count_per_lvl[$treefmt_var_node_level]=$((
        treefmt_var_node_count_per_lvl[$treefmt_var_node_level] + 1
      ))
      [[ $treefmt_var_node_level -lt $treefmt_var_max_lvl ]] ||
        treefmt_var_max_lvl=$treefmt_var_node_level
      treefmt_var_last_node_per_lvl[$treefmt_var_node_level]=$treefmt_var_n
      treefmt_var_type_array[$treefmt_var_n]=$1
      header_array[$treefmt_var_n]=$2
      # record longest node header
      node_header_length=$((treefmt_var_node_level * treefmt_var_indentation_steps + ${#2}))
      [[ $treefmt_var_max_align -gt $node_header_length ]] ||
        treefmt_var_max_align=$node_header_length
      unset node_header_length
      shift 2
      treefmt_var_content_array[$treefmt_var_n]="$*"
      ;;
    body)
      treefmt_var_n=$((treefmt_var_n + 1))
      treefmt_var_level_array[$treefmt_var_n]=$((treefmt_var_node_level + 1))
      treefmt_var_type_array[$treefmt_var_n]=$1
      shift 1
      treefmt_var_content_array[$treefmt_var_n]="$*"
      ;;
    branch)
      case $2 in
        create) ((treefmt_var_node_level++)) ;;
        close)
          # Strings containing all nodes of a given level that are the last in
          # their (sub)branch
          treefmt_var_breaking_nodes[$treefmt_var_node_level]+="${treefmt_var_last_node_per_lvl[$treefmt_var_node_level]} "
          ((treefmt_var_node_level--))
          ;;
      esac
      ;;
    print)
      treefmt_format
      treefmt reset
      ;;
  esac
}

ls_instance() {
  local instance="$1"
  local shortname
  local normalized_shortname=
  local ls_is_extended=

  shortname=$(basename "$instance")

  local user_name=
  local OPENSLIDES_ADMIN_PASSWORD="—"

  [[ -f "${instance}/${DCCONFIG_FILENAME}" ]] && [[ -f "${instance}/config.yml" ]] ||
    fatal "$shortname is not a $DEPLOYMENT_MODE instance."

  #  For stacks, get the normalized shortname
  PROJECT_STACK_NAME="$(value_from_config_yml "$instance" '.stackName')"
  [[ -z "${PROJECT_STACK_NAME}" ]] ||
    local normalized_shortname="${PROJECT_STACK_NAME}"

  # Determine instance state
  local port
  local instance_is_running=
  local sym="$SYM_UNKNOWN"
  local version=
  port="$(value_from_config_yml "$instance" '.port')"
  [[ -n "$port" ]]

  # Check instance deployment state and health
  if ping_instance_simple "$port"; then
    # If we can open a connection to the reverse proxy, the instance has been
    # deployed.
    sym="$SYM_NORMAL"
    instance_is_running=1
    version="[skipped]"
    if [[ -z "$OPT_FAST" ]]; then
      instance_health_status "$port" || sym=$SYM_ERROR
      version=$(currently_running_version)
    fi
  else
    # If we can not connect to the reverse proxy, the instance may have been
    # stopped on purpose or there is a problem
    version=
    sym="$SYM_STOPPED"
    instance_is_running=0
    if [[ -z "$OPT_FAST" ]] &&
        instance_has_services_running "$normalized_shortname"; then
      # The instance has been deployed but it is unreachable
      version=
      sym="$SYM_ERROR"
    fi
  fi

  # Filter online/offline instances
  case "$FILTER_STATE" in
    online)
      [[ "$sym" = "$SYM_NORMAL" ]] || return 1 ;;
    stopped)
      [[ "$sym" = "$SYM_STOPPED" ]] || return 1 ;;
    error)
      [[ "$sym" = "$SYM_ERROR" ]] || [[ "$sym" = "$SYM_UNKNOWN" ]] || return 1 ;;
    *) ;;
  esac

  # Filter based on comparison with the currently running version (as reported
  # by currently_running_version())
  [[ -z "$FILTER_VERSION" ]] ||
    { grep -E -q "$FILTER_VERSION" <<< "$version" || return 1; }

  # Parse metadata for first line (used in overview)
  local first_metadatum=
  if [[ -r "${instance}/metadata.txt" ]]; then
    first_metadatum=$(head -1 "${instance}/metadata.txt")
    # Shorten if necessary.  This string will be printed as a column of the
    # general output, so it should not cause linebreaks.  Since the same
    # information will additionally be displayed in the extended output,
    # we can just cut it off here.
    # Ideally, we'd dynamically adjust to how much space is available.
    [[ "${#first_metadatum}" -lt 31 ]] ||
      first_metadatum="${first_metadatum:0:30}…"
    # Tasks for color support
    if [[ -n "$NCOLORS" ]]; then
      # Colors are enabled.  Since metadata.txt may include escape sequences,
      # reset them at the end
      if grep -Fq $'\e' <<< "$first_metadatum"; then
        first_metadatum+="[0m"
      fi
    else
      # Remove all escapes from comment.  This is the simplest method and will
      # leave behind the disabled escape codes.
      first_metadatum="$(echo "$first_metadatum" | tr -d $'\e')"
    fi
  fi

  # Extended parsing
  # ----------------
  # --services
  if [[ -n "$OPT_SERVICES" ]] || [[ -n "$OPT_JSON" ]]; then
    # Parse currently configured versions from docker-compose.yml
    declare -A service_versions
    while read -r service s_version; do
      service_versions[$service]=$s_version
    done < <(yq eval '.services.*.image | {(path | join(".")): .}' \
        "${instance}/${DCCONFIG_FILENAME}" |
      gawk -F': ' '{ split($1, a, /\./); print a[2], $2}')
    unset service s_version
    # Add management tool version to list of services.  This is not actually
    # a service running inside the stack but a version relevant to the stack
    # nonetheless.
    service_versions[management-tool]=$(value_from_config_yml "$instance" '.managementToolHash') || true

    # Get service scalings
    if [[ -z "$OPT_FAST" ]] && [[ "$instance_is_running" -eq 1 ]]; then
      declare -A service_scaling
      case "$DEPLOYMENT_MODE" in
        "stack")
          while read -r service s_scale; do
            service_scaling[$service]=$s_scale
          done < <(docker stack services --format '{{ .Name }} {{ .Replicas }}' "$normalized_shortname" |
            gawk '{ sub(/^.+_/, "", $1); print } ')
          ;;
      esac
      unset service s_scale
    fi
  fi

  # --secrets
  if [[ -n "$OPT_SECRETS" ]] || [[ -n "$OPT_JSON" ]]; then
    # Parse admin credentials file
    if [[ -r "${instance}/secrets/${ADMIN_SECRETS_FILE}" ]]; then
      read -r OPENSLIDES_ADMIN_PASSWORD \
        < "${instance}/secrets/${ADMIN_SECRETS_FILE}"
    fi
    # Parse user credentials file
    if [[ -r "${instance}/secrets/${USER_SECRETS_FILE}" ]]; then
      local user_secrets="${instance}/secrets/${USER_SECRETS_FILE}"
      local OPENSLIDES_USER_FIRSTNAME=$(yq eval .first_name "${user_secrets}")
      local OPENSLIDES_USER_LASTNAME=$(yq eval .last_name "${user_secrets}")
      local OPENSLIDES_USER_PASSWORD=$(yq eval .default_password "${user_secrets}")
      local OPENSLIDES_USER_EMAIL=$(yq eval .email "${user_secrets}")
      if [[ -n "${OPENSLIDES_USER_FIRSTNAME}" ]] &&
          [[ -n "${OPENSLIDES_USER_LASTNAME}" ]]; then
        user_name="${OPENSLIDES_USER_FIRSTNAME} ${OPENSLIDES_USER_LASTNAME}"
      fi
    fi
  fi

  # --metadata
  local metadata=()
  if [[ -n "$OPT_METADATA" ]] || [[ -n "$OPT_JSON" ]]; then
    if [[ -r "${instance}/metadata.txt" ]]; then
      # Parse metadata file for use in long output
      readarray -t metadata < <(grep -v '^\s*#' "${instance}/metadata.txt")
    fi
  fi

  # JSON ouput
  # ----------
  if [[ -n "$OPT_JSON" ]]; then
    local jq_image_version_args=$(for s in "${!service_versions[@]}"; do
      v=${service_versions[$s]}
      s=$(echo "$s" | tr - _)
      printf -- '--arg %s %s\n' "$s" "$v"
    done)
    local jq_service_scaling_args=$(for s in "${!service_scaling[@]}"; do
      v=${service_scaling[$s]}
      s=$(echo "$s" | tr - _)
      printf -- '--arg %s_scale %s\n' "$s" "$v"
    done)

    # Purposefully not using $JQ here because the output may get piped into
    # another jq process
    jq -n \
      --arg "shortname"     "$shortname" \
      --arg "stackname"     "$normalized_shortname" \
      --arg "directory"     "$instance" \
      --arg "version"       "$version" \
      --arg "instance"      "$instance" \
      --arg "status"        "$sym" \
      --arg "port"          "$port" \
      --arg "superadmin"    "$OPENSLIDES_ADMIN_PASSWORD" \
      --arg "user_name"     "$user_name" \
      --arg "user_password" "$OPENSLIDES_USER_PASSWORD" \
      --arg "user_email"    "$OPENSLIDES_USER_EMAIL" \
      --arg "metadata"      "$(printf "%s\n" "${metadata[@]}")" \
      $jq_image_version_args \
      $jq_service_scaling_args \
      "{
        instances: [
          {
            name:       \$shortname,
            stackname:  \$stackname,
            directory:  \$instance,
            version:    \$version,
            status:     \$status,
            port:       \$port,
            superadmin: \$superadmin,
            user: {
              user_name:    \$user_name,
              user_password: \$user_password,
              user_email: \$user_email
            },
            metadata:   \$metadata,
            services: {
              versions: {
                # Iterate over all known services; their values get defined by jq
                # --arg options.
                $(for s in ${!service_versions[@]}; do
                  printf '"%s": $%s,\n' $s ${s} |
                  tr - _ # dashes not allowed in keys
                done | sort)
              },
              scaling: {
                # Iterate over all known services; their values get defined by jq
                # --arg options.
                $(for s in ${!service_scaling[@]}; do
                  printf '"%s": $%s_scale,\n' $s ${s} |
                  tr - _ # dashes not allowed in keys
                done | sort)
              }
            }
          }
        ]
      }"
    return
  fi

  # Prepare tree output
  # -------------------

  # --long
  if [[ -n "$OPT_LONGLIST" ]]; then
    ls_is_extended=1
    treefmt node "Directory" "$instance"
    if [[ -n "$normalized_shortname" ]]; then
      treefmt node "Stack name" "$normalized_shortname"
    fi
    treefmt node "Local port" "$port"
    treefmt node "Version" "$version"
  fi

  # --services
  if [[ -n "$OPT_SERVICES" ]]; then
    ls_is_extended=1
    treefmt node "Services"
    treefmt branch create
      treefmt node "Versions (configured)"
        treefmt branch create
          for service in $(printf "%s\n" "${!service_versions[@]}" | sort); do
            treefmt node "${service}" "$(highlight_match "${service_versions[$service]}" "$FILTER_VERSION")"
          done
        treefmt branch close
      if [[ -z "$OPT_FAST" ]] && [[ "$instance_is_running" -eq 1 ]]; then
        treefmt node "Scaling"
          treefmt branch create
            for service in $(printf "%s\n" "${!service_scaling[@]}" | sort); do
              treefmt node "${service}" "${service_scaling[$service]}"
            done
          treefmt branch close
      fi
    treefmt branch close
  fi

  # --secrets
  if [[ -n "$OPT_SECRETS" ]]; then
    ls_is_extended=1
    treefmt node "Secrets"
    treefmt branch create
    treefmt node "superadmin" "$OPENSLIDES_ADMIN_PASSWORD"
    # Include secondary account credentials if available
    [[ -n "$user_name" ]] &&
      treefmt node "\"$user_name\"" "$OPENSLIDES_USER_PASSWORD"
    [[ -n "$OPENSLIDES_USER_EMAIL" ]] &&
      treefmt node "Contact" "$OPENSLIDES_USER_EMAIL"
    treefmt branch close
  fi

  # --metadata
  if [[ ${#metadata[@]} -ge 1 ]]; then
    ls_is_extended=1
    treefmt node "Metadata"
    for m in "${metadata[@]}"; do
      m=$(highlight_match "$m") # Colorize match in metadata
      treefmt body "$m"
    done
  fi

  # Print instance
  # --------------
  if [[ "$ls_is_extended" ]]; then
    # Hide details if a long output format has been selected
    printf "%s %-30s\n" "$sym" "$shortname"
  else
    # Print a single line per instance
    printf "%s %-30s\t%-10s\t%s\n" "$sym" "$shortname" \
      "$(highlight_match "$version" "$FILTER_VERSION")" "$first_metadatum"
  fi
  # Formatted tree
  treefmt print
}

colorize_ls() {
  # Colorize the status indicators
  if [[ -n "$NCOLORS" ]] && [[ -z "$OPT_JSON" ]]; then
    # XXX: 2>/dev/null is used here to hide warnings such as
    # gawk: warning: escape sequence `\.' treated as plain `.'
    gawk 2>/dev/null \
      -v m="$PROJECT_NAME" \
      -v hlstart="$(tput smso)" \
      -v hlstop="$(tput rmso)" \
      -v bullet="${BULLET}" \
      -v normal="${COL_NORMAL}" \
      -v green="${COL_GREEN}" \
      -v yellow="${COL_YELLOW}" \
      -v gray="${COL_GRAY}" \
      -v red="${COL_RED}" \
    'BEGIN {
      FPAT = "([[:space:]]*[^[:space:]]+)"
      OFS = ""
      IGNORECASE = 1
    }
    # highlight matches in instance name
    /^[^ ]/ { gsub(m, hlstart "&" hlstop, $2) }
    # highlight matches in metadata
    $1 ~ /[[:space:]]+┆/ { gsub(m, hlstart "&" hlstop, $0) }
    # bullets
    /^OK/   { $1 = " " green  bullet normal }
    /^\?\?/ { $1 = " " yellow bullet normal }
    /^XX/   { $1 = " " red    bullet normal }
    /^__/   { $1 = " " gray   bullet normal }
    1'
  else
    cat -
  fi
}

list_instances() {
  # Find instances and filter based on search term.
  # PROJECT_NAME is used as a grep -E search pattern here.
  local i=()
  local j=()
  readarray -d '' i < <(
    find "${INSTANCES}" -mindepth 1 -maxdepth 1 -type d -print0 |
    sort -z
  )
  for instance in "${i[@]}"; do
    # skip directories that aren't instances
    [[ -f "${instance}/${DCCONFIG_FILENAME}" ]] && [[ -f "${instance}/config.yml" ]] || continue

    # Filter instances
    # 1. instance name/project dir matches (case-insensitive)
    if grep -i -E -q "$PROJECT_NAME" <<< "$(basename "$instance")"; then :
    # 2. metadata matches (case-insensitive)
    elif [[ -n "$OPT_METADATA_SEARCH" ]] && [[ -f "${instance}/metadata.txt" ]] &&
      grep -i -E -q "$PROJECT_NAME" "${instance}/metadata.txt"; then :
    else
      continue
    fi

    j+=("$instance")
  done

  # return here if no matches
  [[ "${#j[@]}" -ge 1 ]] || return

  merge_if_json() {
    if [[ -n "$OPT_JSON" ]]; then
      $JQ -s '{ instances: map(.instances[0]) }'
    else
      cat -
    fi
  }

  # list instances, either one by one or in parallel
  if [[ $OPT_USE_PARALLEL -ne 0 ]]; then
    env_parallel --no-notice --keep-order ls_instance ::: "${j[@]}"
  else
    for instance in "${j[@]}"; do
      ls_instance "$instance" || continue
    done
  fi | colorize_ls | column -ts $'\t' | merge_if_json
}

clone_instance_dir() {
  marker_check "$CLONE_FROM_DIR"
  cp -av "${CLONE_FROM_DIR}/config.yml" "${PROJECT_DIR}/"
  cp -av "${CLONE_FROM_DIR}/secrets/superadmin" "${PROJECT_DIR}/secrets/"
  [[ ! -f "${CLONE_FROM_DIR}/secrets/user.yml" ]] ||
    cp -av "${CLONE_FROM_DIR}/secrets/user.yml" "${PROJECT_DIR}/secrets/"
}

append_metadata() {
  local m="${1}/metadata.txt"
  touch "$m"
  shift
  printf "%s\n" "$*" >> "$m"
}

ask_start() {
  local start=
  read -rp "Start the instance? [Y/n] " start
  case "$start" in
    Y|y|Yes|yes|YES|"")
      instance_start ;;
    *)
      echo "Not starting instance."
      return 2
      ;;
  esac
}

instance_setup_initialdata() {
  # Run setup steps that require the instance to be running
  local PORT=$(value_from_config_yml "$PROJECT_DIR" '.port')
  echo "Waiting for instance to become ready."
  until instance_health_status "$PORT"; do
    sleep 5
  done
  local ec=
  while :; do
    echo "Waiting for datastore to load initial data."
    {
      "${MANAGEMENT_TOOL}" initial-data $(openslides_connect_opts "$PROJECT_DIR")
      ec=$?
    } || :
    # Check initial-data success
    if [[ $ec -eq 0 ]] || [[ $ec -eq 2 ]]; then
      # 0: initial-data was successful; expected during initial setup
      # 2: command refused to run because the database already contains data;
      #    expected during instance_start() after the initial setup
      break
    fi
    sleep 5
  done
}

instance_setup_user() {
  # Add a user if the setup secrets file exists.  After the user has been
  # created, the file is renamed.
  local secret="${PROJECT_DIR}/secrets/${USER_SECRETS_FILE}"
  if [[ -r "${secret}.setup" ]]; then
    "${MANAGEMENT_TOOL}" create-user $(openslides_connect_opts "$PROJECT_DIR") \
      -f "${secret}.setup"
    mv "${secret}.setup" "$secret"
  fi
}

instance_start() {
  # Re-generate docker-compose.yml/docker-stack.yml
  recreate_compose_yml
  case "$DEPLOYMENT_MODE" in
    "stack")
      PROJECT_STACK_NAME="$(value_from_config_yml "$PROJECT_DIR" '.stackName')"
      docker stack deploy -c "$DCCONFIG" "$PROJECT_STACK_NAME"
      ;;
  esac
  instance_setup_initialdata
  instance_setup_user
}

instance_stop() {
  case "$DEPLOYMENT_MODE" in
    "stack")
      docker stack rm "$PROJECT_STACK_NAME"
    ;;
esac
}

instance_erase() {
  case "$DEPLOYMENT_MODE" in
    "stack")
      instance_stop || true
      info "The database will not be deleted automatically for Swarm deployments." \
        "You must set up a mid-erase hook to perform the deletion."
      ;;
  esac
  run_hook mid-erase
}

instance_update() {
  # Update instance to a new version.
  #
  # This function does two things: 1) it updates the instance's config.yml; 2)
  # for running instances, it updates the containers while minimizing service
  # disruptions.  In particular, it ensures that user sessions are not lost.

  # Check if the instance's configuration is suitable for the automatic update.
  #
  # The update function only sets the default tag (.defaults.tag).  More
  # complex configurations, e.g., service-specific tag overrides, can not be
  # updated automatically.  In these cases, require --force.
  #
  if [[ $(yq eval '.services.*.tag' "${PROJECT_DIR}/config.yml" | wc -l) -ne 1 ]] &&
      [[ "$OPT_FORCE" -ne 1 ]]
  then
    fatal "Custom service tags found which cannot be updated automatically! " \
      "Refusing update.  (Use --force to update the default tag anyway.)"
  fi
  # Equally, it would be a concern if there were images from more than one
  # registry in use.  For simplicity's sake, consider any explicitly configured
  # registries a problem.
  if [[ $(yq eval '.services.*.containerRegistry' "${PROJECT_DIR}/config.yml" | wc -l) -ne 1 ]] &&
      [[ "$OPT_FORCE" -ne 1 ]]
  then
    fatal "Custom service containerRegistry found. " \
      "Refusing update.  (Use --force to update the default tag anyway.)"
  fi

  # Update values in config.yml
  [[ -z "$DOCKER_IMAGE_TAG_OPENSLIDES" ]] || {
    update_config_yml "${PROJECT_DIR}/config.yml" \
      ".defaults.tag = \"$DOCKER_IMAGE_TAG_OPENSLIDES\""
    update_config_services_db_connect_params
    recreate_compose_yml
    append_metadata "$PROJECT_DIR" "$(date +"%F %H:%M"): Updated all services to" "${DOCKER_IMAGE_TAG_OPENSLIDES}"
  }

  # Update management tool hash if requested
  [[ -z "$OPT_MANAGEMENT_TOOL" ]] || {
    local cfg_hash=$MANAGEMENT_TOOL_HASH
    if [[ "$OPT_MANAGEMENT_TOOL" = '-' ]]; then
      cfg_hash='-'
    fi
    update_config_yml "${PROJECT_DIR}/config.yml" \
      ".managementToolHash = \"$cfg_hash\""
    append_metadata "$PROJECT_DIR" "$(date +"%F %H:%M"):" \
      "Updated management tool to" "${cfg_hash} ($MANAGEMENT_TOOL_HASH)"
  }

  instance_has_services_running "$PROJECT_STACK_NAME" || {
    warn "${PROJECT_NAME} is not running."
    echo "      The configuration has been updated and the instance will" \
         "be upgraded upon its next start."
    return 0
  }

  # For already running instances, recreate containers with new versions
  instance_start
}

instance_autoscale() {
  declare -A services_changed=()

  log_scale() { # Append to metadata
    for service in ${!services_changed[@]}
    do
      append_metadata "$PROJECT_DIR" "$(date +"%F %H:%M"):"\
	"Autoscaled $service from ${SCALE_FROM[$service]} to ${SCALE_TO[$service]}"
    done
  }

  # arrays used to store scaling info per service
  declare -A SCALE_FROM=()
  declare -A SCALE_TO=()
  declare -A SCALE_RUNNING=()
  declare -A SCALE_COMMANDS=()
  declare -A SCALE_ENVVARS=()

  # .env file handling
  declare -A service_env_var=()
  service_env_var[media]=MEDIA_SERVICE_REPLICAS
  service_env_var[redis-slave]=REDIS_RO_SERVICE_REPLICAS
  service_env_var[server]=OPENSLIDES_BACKEND_SERVICE_REPLICAS
  service_env_var[client]=OPENSLIDES_FRONTEND_SERVICE_REPLICAS
  service_env_var[autoupdate]=OPENSLIDES_AUTOUPDATE_SERVICE_REPLICAS

  get_service_envvar_name() {
    if [[ -v "service_env_var["$1"]" ]]; then
      echo "${service_env_var[$1]}"
    else
      return 1
    fi
  }

  get_scale_env() {
    local from=
    from="$(value_from_env "${PROJECT_DIR}" "$1")"
    # scaling of 1 is empty string in .env
    [[ -n "$from" ]] ||
      from=1
    echo "$from"
  }

  set_scale_env() {
    update_env_file "${PROJECT_DIR}/.env" "$1" "$2" --force
  }

  # if instance not running only env file will be changed
  local running=1
  instance_has_services_running "$PROJECT_STACK_NAME" ||
    running=
  if [[ -z "$running" ]]; then
    warn "${PROJECT_NAME} is not running."
    echo "      The configuration will be updated and changes will take effect" \
         "upon it's next start."
  fi

  # extract number of accounts from instance metadata if not already done before
  if [[ -z "$ACCOUNTS" ]]; then
    [[ -f "${PROJECT_DIR}/metadata.txt" ]] || fatal "metadata.txt does not exist"
    ACCOUNTS="$(gawk '$1 == "ACCOUNTS:" { print $2; exit}' "${PROJECT_DIR}/metadata.txt")"
    [[ -n "$ACCOUNTS" ]] || fatal "ACCOUNTS metadatum not specified for $PROJECT_NAME"
  fi
  # unnessecary check for good measure
  [[ -f "${PROJECT_DIR}/.env" ]] ||
    fatal ".env does not exist"

  # fallback: autoscale everything to 1 if not configured otherwise
  [[ -n "$AUTOSCALE_ACCOUNTS_OVER" ]] ||
    AUTOSCALE_ACCOUNTS_OVER[0]="media=1 redis-slave=1 server=1 client=1 autoupdate=1"
  [[ -n "$AUTOSCALE_RESET_ACCOUNTS_OVER" ]] ||
    AUTOSCALE_RESET_ACCOUNTS_OVER[0]="media=1 redis-slave=1 server=1 client=1 autoupdate=1"

  # parse scale goals from configuration
  # make sure indices are in ascending order
  if [[ -n "$OPT_RESET" ]]; then
    tlist=$(echo "${!AUTOSCALE_RESET_ACCOUNTS_OVER[@]}" | tr " " "\n" | sort -g | tr "\n" " ")
  else
    tlist=$(echo "${!AUTOSCALE_ACCOUNTS_OVER[@]}" | tr " " "\n" | sort -g | tr "\n" " ")
  fi
  for threshold in $tlist; do
    if [[ "$ACCOUNTS" -ge "$threshold" ]]; then
      if [ -n "$OPT_RESET" ]; then
        scalings="${AUTOSCALE_RESET_ACCOUNTS_OVER[$threshold]}"
      else
        scalings="${AUTOSCALE_ACCOUNTS_OVER[$threshold]}"
      fi
      # parse scalings string one by one ...
      while [[ $scalings =~ ^\ *([a-zA-Z0-9-]+)=([0-9]+)\ * ]]; do
        # and update array
        SCALE_TO[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        # truncate parsed info
        scalings="${scalings:${#BASH_REMATCH[0]}}"
      done
      # if len(scalings) != 0 not every value matched the regex
      [[ -z "$scalings" ]] ||
        fatal "scaling values could not be parsed, see: $scalings"
    fi
  done

  if [[ -n "$running" ]]; then
    # ask current scalings from docker
    local docker_str="$(docker stack services --format "{{.Name}} {{.Replicas}}" ${PROJECT_STACK_NAME})"
    for service in "${!SCALE_TO[@]}"
    do
      [[ "$docker_str" =~ "$PROJECT_STACK_NAME"_"$service"[[:space:]]([0-9]+)/([0-9]+) ]]
      SCALE_RUNNING["$service"]="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
      SCALE_FROM["$service"]="${BASH_REMATCH[2]}"
    done
  else
    # ask current scalings from .env file
    local from=
    local envname=
    for service in "${!SCALE_TO[@]}"
    do
      envname=$(get_service_envvar_name "$service") || {
        warn "$service is not configurable in .env, skipping"
        continue
      }
      from=$(get_scale_env "$envname")
      SCALE_RUNNING["$service"]="$from"
      SCALE_FROM["$service"]="$from"
    done
  fi

  # print out overview
  local fmt_str="%-24s %-12s %-12s\n"
  # headline
  if [[ -n "$OPT_RESET" ]]; then
    echo "Resetting scalings of $PROJECT_NAME:"
  else
    echo "$PROJECT_NAME is will be scaled to handle $ACCOUNTS accounts."
  fi
  printf "$fmt_str" "<service>" "<scale from>" "<scale to>"
  # body
  for service in "${!SCALE_FROM[@]}"
  do
    printf "$fmt_str" "$service" "${SCALE_RUNNING[$service]}" "${SCALE_TO[$service]}"
  done

  # determine services on which action needs to be taken
  for service in "${!SCALE_FROM[@]}"
  do
    if [[ -n "$OPT_RESET" || -n "$OPT_ALLOW_DOWNSCALE" ]]; then
      # scale whenever current scale differs from goal
      if [[ "${SCALE_FROM[$service]}" -ne "${SCALE_TO[$service]}" ]]; then
        if [[ -n "$running" ]]; then
          SCALE_COMMANDS[$service]="docker service scale ${PROJECT_STACK_NAME}_${service}=${SCALE_TO[$service]}"
        fi
        envname=$(get_service_envvar_name "$service") || {
          warn "$service is not configurable in .env, scale will not persist"
          continue
        }
        SCALE_ENVVARS[$service]="set_scale_env $envname ${SCALE_TO[$service]}"
      fi
    else
      # only scale upward in case a service has manually been upscaled unexpectedly high
      if [[ ${SCALE_FROM[$service]} -lt ${SCALE_TO[$service]} ]]; then
        if [[ -n "$running" ]]; then
          SCALE_COMMANDS[$service]="docker service scale ${PROJECT_STACK_NAME}_${service}=${SCALE_TO[$service]}"
        fi
        envname=$(get_service_envvar_name "$service") || {
          warn "$service is not configurable in .env, scale will not persist"
          continue
        }
        SCALE_ENVVARS[$service]="set_scale_env $envname ${SCALE_TO[$service]}"
      fi
    fi
  done

  # no commands or env updates generated, i.e. all services are already appropriately scaled
  if [[ ${#SCALE_COMMANDS[@]} -eq 0 && ${#SCALE_ENVVARS[@]} -eq 0 ]]
  then
    echo "No action required"
    return 0
  fi

  # if dry run, print commands + env updates instead of performing them
  if [[ -n "$OPT_DRY_RUN" ]]; then
      echo "!DRY RUN!"
  fi
  # docker scale commands 
  for service in "${!SCALE_COMMANDS[@]}"
  do
    if [[ -n "$OPT_DRY_RUN" ]]; then
        echo "${SCALE_COMMANDS[$service]}"
    else
      ${SCALE_COMMANDS[$service]}
      services_changed[$service]=1
    fi
  done
  # env updates
  for service in "${!SCALE_ENVVARS[@]}"
  do
    if [[ -n "$OPT_DRY_RUN" ]]; then
        echo "${SCALE_ENVVARS[$service]}"
    else
      ${SCALE_ENVVARS[$service]}
      services_changed[$service]=1
    fi
  done

  log_scale
}

run_hook() (
  local hook hook_name
  [[ -d "$HOOKS_DIR" ]] || return 0
  hook_name="$1"
  hook="${HOOKS_DIR}/${hook_name}"
  shift
  if [[ -x "$hook" ]]; then
    cd "$PROJECT_DIR"
    info "Running $hook_name hook..."
    set +eu
    . "$hook"
    set -eu
  fi
  )

# In order to be able to switch deployment modes, it should probably be added
# as an explicit option.  The program name based setting (osinstancectl vs.
# osstackctl) has led to problems in the past.
DEPLOYMENT_MODE=stack

shortopt="halsjmiMnfed:t:O:"
longopt=(
  help
  color:
  json
  project-dir:
  force

  # display options
  long
  services
  secrets
  metadata

  # Template opions
  compose-template:
  config-template:

  # filtering
  all
  online
  offline
  error
  fast
  patient
  search-metadata
  version:

  # adding instances
  clone-from:
  local-only
  no-add-account

  # adding & upgrading instances
  tag:
  management-tool:

  # autoscaling
  allow-downscale
  reset-scale
  accounts:
  dry-run
)
# format options array to comma-separated string for getopt
longopt=$(IFS=,; echo "${longopt[*]}")

ARGS=$(getopt -o "$shortopt" -l "$longopt" -n "$ME" -- "$@")
if [ $? -ne 0 ]; then usage; exit 1; fi
eval set -- "$ARGS";
unset ARGS

# Config file
if [[ -f "$CONFIG" ]]; then
  source "$CONFIG"
fi

# Parse options
while true; do
  case "$1" in
    -d|--project-dir)
      PROJECT_DIR="$2"
      shift 2
      ;;
    --compose-template)
      COMPOSE_TEMPLATE="$2"
      [[ -r "$COMPOSE_TEMPLATE" ]] || fatal "$COMPOSE_TEMPLATE not found."
      shift 2
      ;;
    --config-template)
      CONFIG_YML_TEMPLATE="$2"
      [[ -r "$CONFIG_YML_TEMPLATE" ]] || fatal "$CONFIG_YML_TEMPLATE not found."
      shift 2
      ;;
    -t|--tag)
      DOCKER_IMAGE_TAG_OPENSLIDES="$2"
      shift 2
      ;;
    -O | --management-tool)
      OPT_MANAGEMENT_TOOL=$2
      shift 2
      ;;
    --no-add-account)
      OPT_ADD_ACCOUNT=
      shift 1
      ;;
    -a|--all)
      OPT_LONGLIST=1
      OPT_METADATA=1
      OPT_IMAGE_INFO=1
      OPT_SECRETS=1
      OPT_SERVICES=1
      shift 1
      ;;
    --services)
      OPT_SERVICES=1
      shift 1
      ;;
    -l|--long)
      OPT_LONGLIST=1
      shift 1
      ;;
    -s|--secrets)
      OPT_SECRETS=1
      shift 1
      ;;
    -m|--metadata)
      OPT_METADATA=1
      shift 1
      ;;
    -M|--search-metadata)
      OPT_METADATA_SEARCH=1
      shift 1
      ;;
    -j|--json)
      OPT_JSON=1
      shift 1
      ;;
    -n|--online)
      FILTER_STATE="online"
      shift 1
      ;;
    -f|--offline)
      FILTER_STATE="stopped"
      shift 1
      ;;
    -e|--error)
      FILTER_STATE="error"
      shift 1
      ;;
    --version)
      FILTER_VERSION="$2"
      shift 2
      ;;
    --clone-from)
      CLONE_FROM="$2"
      shift 2
      ;;
    --local-only)
      OPT_LOCALONLY=1
      shift 1
      ;;
    --color)
      OPT_COLOR="$2"
      shift 2
      ;;
    --force)
      OPT_FORCE=1
      shift 1
      ;;
    --fast)
      OPT_FAST=1
      OPT_PATIENT=
      shift 1
      ;;
    --patient)
      OPT_PATIENT=1
      OPT_USE_PARALLEL=0
      OPT_FAST=
      CURL_OPTS=(--max-time 60 --retry 5 --retry-delay 1 --retry-max-time 0)
      shift 1
      ;;
    --allow-downscale)
      OPT_ALLOW_DOWNSCALE=1
      shift 1
      ;;
    --reset-scale)
      OPT_RESET=1
      shift 1
      ;;
    --accounts)
      ACCOUNTS="$2"
      shift 2
      ;;
    --dry-run)
      OPT_DRY_RUN=1
      shift 1
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift ; break ;;
    *) usage; exit 1 ;;
  esac
done

# Parse commands
for arg; do
  case $arg in
    ls|list)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=list
      shift 1
      ;;
    add|create)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=create
      [[ -z "$CLONE_FROM" ]] || MODE=clone
      shift 1
      ;;
    rm|remove)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=remove
      shift 1
      ;;
    start|up)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=start
      shift 1
      ;;
    stop|down)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=stop
      shift 1
      ;;
    erase)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=erase
      shift 1
      ;;
    update)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=update
      [[ -n "$DOCKER_IMAGE_TAG_OPENSLIDES" ]] || [[ -n "$OPT_MANAGEMENT_TOOL" ]] ||
        fatal "Update requires tag or management tool option"
      shift 1
      ;;
    autoscale)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=autoscale
      shift 1
      ;;
    *)
      # The final argument should be the project name/search pattern
      PROJECT_NAME="$arg"
      break
      ;;
  esac
done

# Use GNU parallel if found
if [[ "$OPT_USE_PARALLEL" -ne 0 ]] && [[ -f /usr/bin/env_parallel.bash ]]; then
  source /usr/bin/env_parallel.bash
  OPT_USE_PARALLEL=1
fi

case "$OPT_COLOR" in
  auto)
    if [[ -t 1 ]]; then enable_color; fi ;;
  always)
    enable_color ;;
  never) true ;;
  *)
    fatal "Unknown option to --color" ;;
esac


DEPS=(
  docker
  gawk
  jq
  yq
  m4
  nc
)
# Check dependencies
for i in "${DEPS[@]}"; do
    check_for_dependency "$i"
done

# PROJECT_NAME should be lower-case
PROJECT_NAME="$(echo "$PROJECT_NAME" | tr '[A-Z]' '[a-z]')"

# Prevent --project-dir to be used together with a project name
if [[ -n "$PROJECT_DIR" ]] && [[ -n "$PROJECT_NAME" ]]; then
  fatal "Mutually exclusive options"
fi
# Deduce project name from path
if [[ -n "$PROJECT_DIR" ]]; then
  PROJECT_NAME="$(basename "$(readlink -f "$PROJECT_DIR")")"
  OPT_METADATA_SEARCH=
# Treat the project name "." as --project-dir=.
elif [[ "$PROJECT_NAME" = "." ]]; then
  PROJECT_NAME="$(basename "$(readlink -f "$PROJECT_NAME")")"
  PROJECT_DIR="${INSTANCES}/${PROJECT_NAME}"
  OPT_METADATA_SEARCH=
  # Signal that the project name is based on the directory and could be
  # transformed into a more precise regexp internally:
  OPT_PRECISE_PROJECT_NAME=1
else
  PROJECT_DIR="${INSTANCES}/${PROJECT_NAME}"
fi

# The project name is a valid domain which is not suitable as a Docker
# stack name.  Here, we remove all dots from the domain which turns the
# domain into a compatible name.  This also appears to be the method
# docker-compose uses to name its containers, networks, etc.
PROJECT_STACK_NAME="$(echo "$PROJECT_NAME" | tr -d '.')"

case "$DEPLOYMENT_MODE" in
  "stack")
    DCCONFIG_FILENAME="docker-stack.yml"
    ;;
esac
DCCONFIG="${PROJECT_DIR}/${DCCONFIG_FILENAME}"

case "$MODE" in
  remove)
    arg_check || { usage; exit 2; }
    [[ -n "$OPT_FORCE" ]] || marker_check "$PROJECT_DIR" ||
      fatal "Refusing to delete unless --force is given."
    # Ask for confirmation
    ANS=
    echo "Delete the following instance including all of its data and configuration?"
    # Show instance listing
    OPT_LONGLIST=1 OPT_METADATA=1 OPT_METADATA_SEARCH= \
      ls_instance "$PROJECT_DIR" | colorize_ls
    echo
    read -rp "Really delete? (uppercase YES to confirm) " ANS
    [[ "$ANS" = "YES" ]] || exit 0
    run_hook "pre-${MODE}"
    remove "$PROJECT_NAME"
    ;;
  create)
    [[ -f "$CONFIG" ]] && echo "Applying options from ${CONFIG}." || true
    arg_check || { usage; exit 2; }
    # Use defaults in the absence of options
    echo "Creating new instance: $PROJECT_NAME"
    # If not specified, set management tool to "-", i.e., track the latest
    # version
    [[ -n "$OPT_MANAGEMENT_TOOL" ]] || OPT_MANAGEMENT_TOOL="-"
    query_user_account_name
    select_management_tool
    PORT=$(next_free_port)
    create_instance_dir
    update_config_instance_specifics
    create_admin_secrets_file
    create_user_secrets_file "${OPENSLIDES_USER_FIRSTNAME}" \
      "${OPENSLIDES_USER_LASTNAME}" "${OPENSLIDES_USER_EMAIL}"
    update_config_services_db_connect_params
    recreate_compose_yml
    append_metadata "$PROJECT_DIR" ""
    append_metadata "$PROJECT_DIR" \
      "$(date +"%F %H:%M"): Instance created (${DEPLOYMENT_MODE})"
    append_metadata "$PROJECT_DIR" \
      "$(date +"%F %H:%M"): image=$DOCKER_IMAGE_TAG_OPENSLIDES manage=$MANAGEMENT_TOOL_HASH"
    [[ -z "$OPT_LOCALONLY" ]] ||
      append_metadata "$PROJECT_DIR" "No HAProxy config added (--local-only)"
    add_to_haproxy_cfg
    run_hook "post-${MODE}"
    # read accounts for autoscale
    if [[ -f "${PROJECT_DIR}/metadata.txt" ]]; then
      ACCOUNTS="$(gawk '$1 == "ACCOUNTS:" { print $2; exit}' "${PROJECT_DIR}/metadata.txt")"
      if [[ -n "$ACCOUNTS" ]]; then
        # initially set to non-power mode (= --reset)
        OPT_RESET=1
        instance_autoscale
      fi
    fi
    ask_start || true
    ;;
  clone)
    CLONE_FROM_DIR="${INSTANCES}/${CLONE_FROM}"
    arg_check || { usage; exit 2; }
    echo "Creating new instance: $PROJECT_NAME (based on $CLONE_FROM)"
    select_management_tool
    PORT=$(next_free_port)
    run_hook "pre-${MODE}"
    create_instance_dir
    clone_instance_dir
    update_config_instance_specifics
    update_config_services_db_connect_params
    recreate_compose_yml
    append_metadata "$PROJECT_DIR" ""
    append_metadata "$PROJECT_DIR" "Cloned from $CLONE_FROM on $(date)"
    append_metadata "$PROJECT_DIR" \
      "$(date +"%F %H:%M"): image=$(value_from_config_yml "$PROJECT_DIR" '.defaults.tag')" \
      "manage=$MANAGEMENT_TOOL_HASH"
    [[ -z "$OPT_LOCALONLY" ]] ||
      append_metadata "$PROJECT_DIR" "No HAProxy config added (--local-only)"
    add_to_haproxy_cfg
    run_hook "post-${MODE}"
    ask_start || true
    ;;
  list)
    [[ -z "$OPT_PRECISE_PROJECT_NAME" ]] || PROJECT_NAME="^${PROJECT_NAME}$"
    list_instances
    ;;
  start)
    arg_check || { usage; exit 2; }
    select_management_tool
    instance_start
    run_hook "post-${MODE}"
    ;;
  stop)
    arg_check || { usage; exit 2; }
    instance_stop
    run_hook "post-${MODE}"
    ;;
  erase)
    arg_check || { usage; exit 2; }
    # Ask for confirmation
    ANS=
    echo "Stop the following instance, and remove its containers and volumes?"
    # Show instance listing
    OPT_LONGLIST=1 OPT_METADATA=1 OPT_METADATA_SEARCH= \
      ls_instance "$PROJECT_DIR" | colorize_ls
    echo
    read -rp "Really delete? (uppercase YES to confirm) " ANS
    [[ "$ANS" = "YES" ]] || exit 0
    instance_erase
    ;;
  update)
    [[ -f "$CONFIG" ]] && echo "Applying options from ${CONFIG}." || true
    arg_check || { usage; exit 2; }
    select_management_tool
    run_hook "pre-${MODE}"
    instance_update
    run_hook "post-${MODE}"
    ;;
  autoscale)
    [[ -f "$CONFIG" ]] && echo "Applying options from ${CONFIG}." || true
    arg_check || { usage; exit 2; }
    instance_autoscale
    ;;
  *)
    fatal "Missing command.  Please consult $ME --help."
    ;;
esac
