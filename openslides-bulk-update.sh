#!/bin/bash

# This script iterates over a number of OpenSlides Docker instances and updates
# them to the given tag.
#
# -------------------------------------------------------------------
# Copyright (C) 2020 by Intevation GmbH
# Author(s):
# Gernot Schulz <gernot@intevation.de>
#
# This program is distributed under the MIT license, as described
# in the LICENSE file included with the distribution.
# SPDX-License-Identifier: MIT
# -------------------------------------------------------------------

OSCTL=os4instancectl
INSTANCES=()
UPDATE_ERRORS=()
PATTERN=
TAG=
OPT_MANAGEMENT_TOOL=
ME="$(basename -s .sh "${BASH_SOURCE[0]}")"
MIN_WIDTH=64
DEFAULT_OPT_JOBS=3

usage() {
cat << EOF
Usage: $ME --tag=<tag> --management-tool=<tool> [<options>] < <instances in JSON format>

Required parameters:
  -t TAG, --tag=TAG       Docker image tag to which to update
  -O TOOL,
  --management-tool=TOOL  Specify the management tool version to use.  This
                          option is passed through to $OSCTL, so see
                          \`$OSCTL help update\` for details.

Optional parameters:
  -j JOBS, --jobs=JOBS    Configure the number of jobs to run in parallel
                          (default: $DEFAULT_OPT_JOBS)
  --tmux                  Display jobs in tmux windows
  --tmuxpanes             Display jobs in tmux panes

$ME expects the output of "os4instancectl ls --json" on its standard input.

Example:

  os4instancectl --json ls staging | $ME --tag=4.0.0-new-version
EOF
}

fatal() {
    echo 1>&2 "ERROR: $*"
    exit 23
}

instance_menu() {
  local tag
  local instances
  local width=$((MAX_LENGTH + 10))
  tag="$1"
  shift
  [[ $width -ge "$MIN_WIDTH" ]] || width="$MIN_WIDTH"

  if [[ ${#*} -eq 0 ]]; then
    whiptail \
      --backtitle "OpenSlides bulk update" \
      --title "Error" \
      --msgbox "Error: No instances found in input" 10 "$MIN_WIDTH" \
    3>&2 2>&1 1>&3
    return 1
  fi

  whiptail --title "OpenSlides bulk update" \
    --checklist "Select instances to include in bulk update to tag $tag" \
    25 $width 16 \
    --separate-output \
    --clear \
    $@ \
    3>&2 2>&1 1>&3
}

shortopt="ht:O:j:"
longopt="help,tag:,management-tool:,jobs:,tmux,tmuxpanes"
ARGS=$(getopt -o "$shortopt" -l "$longopt" -n "$ME" -- "$@")
if [ $? -ne 0 ]; then usage; exit 1; fi
eval set -- "$ARGS"
unset ARGS
# Parse options
while true; do
  case "$1" in
    -t | --tag)
      TAG="$2"
      shift 2
      ;;
    -O | --management-tool)
      OPT_MANAGEMENT_TOOL="$2"
      shift 2
      ;;
    -j | --jobs)
      OPT_PARALLEL_JOBS="$2"
      shift 2
      ;;
    --tmux)
      OPT_PARALLEL_TMUX="--tmux"
      shift 1
      ;;
    --tmuxpanes)
      OPT_PARALLEL_TMUX="--tmuxpane"
      shift 1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --) shift ; break ;;
    *) usage; exit 1 ;;
  esac
done
PATTERN="$@"


# Verify dependencies
DEPS=(
  "$OSCTL"
  whiptail
  parallel
)
for i in "${DEPS[@]}"; do
  command -v "$i" > /dev/null || { fatal "Dependency not found: $i"; }
done
# Verify that the /correct/ parallel is available
parallel -V 2>&1 >/dev/null || fatal "GNU parallel not found."
# Verify options
[[ -n "$TAG" ]] || { fatal "Missing option: --tag"; }
[[ -n "$OPT_MANAGEMENT_TOOL" ]] ||
  fatal "You have not specified the OpenSlides management tool version" \
    "(--management-tool)."

mkdir -p /var/log/openslides-bulk-update
PARALLEL_RESULT_DIR="$(mktemp -d --tmpdir=/var/log/openslides-bulk-update $(date -I).XXX)" || exit 23
PARALLEL_JOBLOG="${PARALLEL_RESULT_DIR}/joblog"

# Read instance listing from os4instancectl on stdin
JSON_DATA=$(jq .) || fatal "Input is not in JSON format."
NUM_INSTANCES=$(jq '.instances | length' <<< "$JSON_DATA")

until [[ ${n:=0} -eq $NUM_INSTANCES ]]; do
  # Note: JSON array is zero-indexed while NUM_INSTANCES is the absolute number
  # of objects.
  instance=$(jq -r --argjson n "$n" '.instances[$n].name' <<< "$JSON_DATA")
  version=$(jq -r --argjson n "$n" '.instances[$n].version' <<< "$JSON_DATA")
  status=$(jq -r --argjson n "$n" '.instances[$n].status' <<< "$JSON_DATA")
  [[ -n "$status" ]] || continue
  # Pre-select instances
  checked="OFF"
  if [[ -z "$version" ]]; then
    version="parsing_error"
  elif [[ "$version" =~ [0-9]\]$ ]]; then
    # Deselect instances with non-homogeneous service versions, e.g.,
    # 4.0.0-dev-20220110-670bbdb(11)/example-bugfix(1)[2:2].  The presence of
    # the final square brackets is a simple method to identify complex
    # version strings.
    :
  elif [[ "$version" != "$TAG" ]]; then
    # Only select instances not already up to date
    checked="ON"
    # # Only select online instances
    # if [[ "$status" = "OFF" ]]; then
    #   checked="OFF"
    #   version="offline"
    # fi
  fi
  # Prepare output for whiptail
  fmt="$(printf "%s (%s) %s\n" "$instance" "$version" "$checked")"
  [[ ${#fmt} -le "$MAX_LENGTH" ]] || MAX_LENGTH=${#fmt}
  INSTANCES+=("$fmt")
  ((n++))
done

INSTANCES=($(instance_menu "$TAG" "${INSTANCES[@]}")) # User-selected instances
if [[ $? -eq 0 ]]; then clear; else exit 3; fi
[[ ${#INSTANCES[@]} -ge 1 ]] || exit 0

if [[ -z "$OPT_PARALLEL_TMUX" ]]; then
  # Logging to the result files only works if the tmux options are not set.
  # Otherwise, the files are created but will remain empty, so their location
  # is only relevant when the script is executed without tmux.
  echo "Logging to ${PARALLEL_RESULT_DIR}/."
fi
parallel --no-run-if-empty --tag --bar \
    --joblog "$PARALLEL_JOBLOG" --result "$PARALLEL_RESULT_DIR" \
    --delay 0.5 --jobs=${OPT_PARALLEL_JOBS:=$DEFAULT_OPT_JOBS} $OPT_PARALLEL_TMUX \
  "$OSCTL" --no-pid-file --color=never \
    --tag="$TAG" --management-tool="$OPT_MANAGEMENT_TOOL" \
    update '{}' ::: "${INSTANCES[@]}" || ec=$?
if [[ $ec -ne 0 ]]; then
  echo
  echo "ERRORS ENCOUNTERED! ($PARALLEL_JOBLOG):"
  echo
  # Retrieve failed jobs (and their sequence number) from joblog
  awk -F $'\t' 'NR > 1 && $7 != 0 { printf(" - %02d: %s\n", $1, $9) }' "$PARALLEL_JOBLOG"
  if [[ -z "$OPT_PARALLEL_TMUX" ]]; then
    echo
    echo "Find the logs in $PARALLEL_RESULT_DIR/."
  fi
fi
exit $ec
