#!/bin/bash

# -------------------------------------------------------------------
# Copyright (C) 2021 by Intevation GmbH
# Author(s):
# Gernot Schulz <gernot@intevation.de>
#
# This program is distributed under the MIT license, as described
# in the LICENSE file included with the distribution.
# SPDX-License-Identifier: MIT
# -------------------------------------------------------------------

# OpenSlides manage tool downloader.  See usage() for more information.

# Defaults
DEFAULT_URL="https://github.com/OpenSlides/openslides-manage-service/releases/download/latest/openslides"
DEFAULT_BINDIR="/usr/local/lib/openslides-manage/versions"

set -eu
ME=$(basename -s .sh "${BASH_SOURCE[0]}")
TEMPFILE=
URL=
BINDIR=
HASH=
OPT_FORCE=
OPT_LINK=1

cleanup() {
  if [[ -e "$TEMPFILE" ]]; then
    rm -rf "$TEMPFILE"
  fi
}

usage() {
  cat << EOF
Usage: $ME [<options>]

$ME downloads the latest version of the OpenSlides management tool and installs
it alongside older versions under the file's hash sum.  Additionally, the
downloaded version is symlinked as 'latest'.

Hint: Symlink /usr/local/bin/openslides to '<bindir>/latest'.

Options:
  -u, --url             Download URL (default: $DEFAULT_URL)
  -b, --bindir          Installation directory (default: $DEFAULT_BINDIR)
  --force               Force reinstallation
  --no-link             Do not create symlink 'latest' symlink
  -h, --help
EOF
}

trap cleanup EXIT

shortopt="hu:b:"
longopt="help,force,url:,bindir:,no-link"
ARGS=$(getopt -o "$shortopt" -l "$longopt" -n "$ME" -- "$@")
if [ $? -ne 0 ]; then usage; exit 1; fi
eval set -- "$ARGS"
unset ARGS
while true; do
  case "$1" in
    -u | --url)
      URL=$2
      shift 2
      ;;
    -b | --bindir)
      BINDIR=$2
      shift 2
      ;;
    --force)
      OPT_FORCE=1
      shift
      ;;
    --no-link)
      OPT_LINK=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --) shift ; break ;;
    *) usage; exit 1 ;;
  esac
done

[[ -n "$URL" ]]    || URL=$DEFAULT_URL
[[ -n "$BINDIR" ]] || BINDIR=$DEFAULT_BINDIR

mkdir -p "$BINDIR"
TEMPFILE=$(mktemp)

echo "Downloading $URL."
curl -L --output "$TEMPFILE" "$URL"

read -r HASH x < <(sha256sum "$TEMPFILE")
unset x
LATEST="${BINDIR}/${HASH}"

if [[ -z "$OPT_FORCE" ]] && [[ -x "$LATEST" ]] && [[ "$(basename "$(realpath "${BINDIR}/latest")")" = "$HASH" ]]
then
  echo "Newest version already available."
  exit 0
fi

echo "Testing functionality with --help."
chmod +x "$TEMPFILE"
if "$TEMPFILE" --help > /dev/null; then
  echo "Functionality test succeeded."
else
  echo "ERROR: The program was installed but it not appears to be functional." 1>&2
  exit 23
fi

echo "Installing as $LATEST."
install -m 755 "$TEMPFILE" "$LATEST"

[[ "$OPT_LINK" -eq 0 ]] || ln -sf "$HASH" "${BINDIR}/latest"
