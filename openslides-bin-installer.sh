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
DEFAULT_REPO="https://github.com/OpenSlides/OpenSlides"
DEFAULT_BINDIR="/usr/local/lib/openslides-manage"

set -eu
ME=$(basename -s .sh "${BASH_SOURCE[0]}")
TEMPFILE=
BUILD_DIR=
URL=
REPO=
BINDIR=
REV=
HASH=
OPT_FORCE=
OPT_LINK=1

cleanup() {
  if [[ -e "$TEMPFILE" ]]; then
    rm -rf "$TEMPFILE"
  fi
  if [[ -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
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
  -u, --url=URL           Download URL (default:
                          $DEFAULT_URL)
  -r,
  --build-revision=REV    Build "openslides" from source to be compatible with
                          the given central repository version (default
                          repository: $DEFAULT_REPO)
  -b, --bindir=DIR        Installation directory (default: $DEFAULT_BINDIR)
  --force                 Force reinstallation
  --no-link               Do not create symlink 'latest' symlink
  -h, --help
EOF
}

prereq_check() {
  command -v docker > /dev/null || {
    echo "ERROR: docker not found."
    exit 23
  }
}

install_version(){
  # Install the binary under its own hash
  echo "Installing as $LATEST."
  install -m 755 "$TEMPFILE" "$LATEST"
  [[ "$OPT_LINK" -eq 0 ]] || {
    echo "Linking as ${BINDIR}/versions/latest."
    ln -sf "$HASH" "${BINDIR}/versions/latest"
  }
}

trap cleanup EXIT

shortopt="hu:b:r:"
longopt="help,force,url:,bindir:,no-link,build-revision:"
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
    -r | --build-revision)
      REV=$2
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

if [[ $# -ne 0 ]]; then
  printf "ERROR: Wrong number of arguments.\n\n"
  usage
  exit 23
fi

[[ -n "$URL" ]]    || URL=$DEFAULT_URL
[[ -n "$REPO" ]]   || REPO=$DEFAULT_REPO
[[ -n "$BINDIR" ]] || BINDIR=$DEFAULT_BINDIR

mkdir -p "$BINDIR"/versions
TEMPFILE=$(mktemp --suffix .bin)

# Build or download
if [[ "$REV" ]]; then
  prereq_check
  echo "Building $REV."
  BUILD_DIR=$(mktemp -d --suffix .git)
  git clone -q --no-checkout --depth=100 --shallow-submodules "$REPO" "$BUILD_DIR"
  if COMMIT=$(git -C "$BUILD_DIR" rev-parse -q --verify "$REV"); then :
  elif [[ "$REV" =~ .*-([0-9a-f]+$) ]]; then
    # OpenSlides versions have the format 4.0.0-dev-20211125-845f8c5 which
    # includes the Git revision, in this case 845f8c5.  If regular revision
    # parsing failed above, maybe the given commit is such a version.  For
    # convenience, we try to deduce the revision from this, strictly speaking,
    # invalid input.
    REV_SUBSTR=${BASH_REMATCH[1]}
    echo "WARN: $REV is not a valid Git revision; trying ${REV_SUBSTR} for your convenience."
    COMMIT=$(git -C "$BUILD_DIR" rev-parse -q --verify "$REV_SUBSTR") || {
      echo "ERROR: $REV_SUBSTR is not a valid or unique git revision."
      exit 2
    }
    unset REV_SUBSTR
  else
    echo "ERROR: $REV is not a valid or unique git revision."
    exit 2
  fi
  git -C "$BUILD_DIR" config advice.detachedHead false # Avoid warning
  git -C "$BUILD_DIR" checkout -q "$COMMIT"
  git -C "$BUILD_DIR" submodule -q init openslides-manage-service
  git -C "$BUILD_DIR" submodule update openslides-manage-service
  (
    cd "${BUILD_DIR}/openslides-manage-service"
    make openslides
    mv openslides "$TEMPFILE"
  )
else
  echo "Downloading $URL."
  curl -L --output "$TEMPFILE" "$URL"
fi

read -r HASH x < <(sha256sum "$TEMPFILE")
unset x
LATEST="${BINDIR}/versions/${HASH}"

echo "Testing functionality with --help."
chmod +x "$TEMPFILE"
if "$TEMPFILE" --help > /dev/null; then
  echo "Functionality test succeeded."
else
  echo "ERROR: The program was installed but it not appears to be functional." 1>&2
  exit 23
fi

if [[ "$REV" ]]; then
  # If built from source, create git commit-based symlink
  COMMITS_DIR=$(realpath "${BINDIR}/commits")
  mkdir -p "$COMMITS_DIR"
  COMMITS_PATH="${COMMITS_DIR}/${COMMIT}"
  if [[ -z "$OPT_FORCE" ]] && [[ -h "$COMMITS_PATH" ]] && [[ -x "$(realpath "$COMMITS_PATH")" ]]; then
    echo "A version for this commit is already available."
  else
    install_version
    echo "Linking as $COMMITS_PATH."
    ln -sf "../versions/${HASH}" "$COMMITS_PATH"
  fi
elif [[ -z "$OPT_FORCE" ]] && [[ -x "$LATEST" ]] &&
    [[ "$(basename "$(realpath "${BINDIR}/versions/latest")")" = "$HASH" ]]; then
  echo "Newest version already available."
else
  install_version
fi
