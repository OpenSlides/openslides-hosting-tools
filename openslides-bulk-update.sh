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
TIME=
ME="$(basename -s .sh "${BASH_SOURCE[0]}")"
MIN_WIDTH=64

usage() {
cat << EOF
Usage: $ME [<options>] --tag <tag> < INSTANCES

  -t TAG, --tag=TAG   Docker image tag to which to update
  --at=TIME           "at" timespec, cf. \`man at\`

$ME expects the output of "osinstancectl ls" on its standard input.
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
    $* \
    3>&2 2>&1 1>&3
}

shortopt="ht:"
longopt="help,tag:,at:"
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
    --at)
      TIME="$2"
      shift 2
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
  at
  chronic
)
for i in "${DEPS[@]}"; do
  command -v "$i" > /dev/null || { fatal "Dependency not found: $i"; }
done
# Verify options
[[ -n "$TAG" ]] || { fatal "Missing option: --tag"; }

# Read instance listing from os4instancectl on stdin
while IFS= read -r line; do
  # Skip irrelevant lines, probably from ls --long
  grep -q '^[^\ ]' <<< "$line" || continue
  read -r status instance version memo <<< "$line"
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
done

INSTANCES=($(instance_menu "$TAG" "${INSTANCES[@]}")) # User-selected instances
if [[ $? -eq 0 ]]; then clear; else exit 3; fi
[[ ${#INSTANCES[@]} -ge 1 ]] || exit 0

if [[ -z "$TIME" ]]; then
  # Execute immediately
  n=0
  for i in "${INSTANCES[@]}"; do
    (( n++ ))
    str=" Updating ${i} (${n}/${#INSTANCES[@]})... "
    echo
    echo "$str" | sed -e 's/./—/g'
    echo "$str"
    echo "$str" | sed -e 's/./—/g'
    "$OSCTL" --tag "$TAG" update "$i" || UPDATE_ERRORS+=($i)
  done
  if [[ ${#UPDATE_ERRORS[@]} -ge 1 ]]; then
    printf "\nWARNING: Instances that reported update errors:\n"
    printf " - %s\n" "${UPDATE_ERRORS[@]}"
  fi
else
  # Prepare "at" job
  for i in "${INSTANCES[@]}"; do
    echo "chronic \"$OSCTL\" --tag \"$TAG\" update \"$i\""
  done |
  at "$TIME"
fi
