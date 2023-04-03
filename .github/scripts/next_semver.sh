#!/usr/bin/env bash

set -o errexit
set -o nounset
set -x

SCRIPT_NAME="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"
CG1="(0|[1-9]\d*)"
CG2="(0|[1-9]\d*)"
CG3="(0|[1-9]\d*)"
REGEXP="$CG1\.$CG2\.$CG3(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-]\
[0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-\
Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"

if [[ $# -lt 2 ]]; then
  cat <<-EOF
  Usage: $SCRIPT_NAME <tag_prefix> <PR number> <major|minor|patch> <default version>

  Example:
    # Current version is 0.6.2 
    $SCRIPT_NAME secure-forwarder 1 minor '0.0.0'
    0.7.0-pr1

EOF
  exit 1
fi

tmp_vert=$(mktemp)
curl -o "$tmp_vert" -sL https://github.com/Masterminds/vert/releases/download/v0.1.0/vert-v0.1.0-linux-amd64
chmod a+x "$tmp_vert"

tag_prefix=${1:-""}
pr_number=${2:-"none"}
bump=${3:-"patch"}
default_version=${4:-""}

version="$( git --no-pager tag -l | grep "$tag_prefix" | grep -o -P "$REGEXP" | xargs "$tmp_vert" -s "*" 2> /dev/null | tail -n 1 )"
rm -f rm -f "$tmp_vert"
if [[ -z $version ]]; then
  if [[ -z $default_version ]]; then
    echo "no version found"
    exit 1
  else
    version="$default_version"
  fi
fi

major="$( echo -n "$version" | awk '{split($0,a,"."); print a[1]}')"
minor="$( echo -n "$version" | awk '{split($0,a,"."); print a[2]}')"
patch="$( echo -n "$version" | awk '{split($0,a,"."); print a[3]}')"

case $bump in
  major)
    major=$(( major + 1 ))
    minor='0'
    patch='0'
    ;;
  minor)
    minor=$(( minor + 1 ))
    patch='0'
    ;;
  *)
    patch=$(( patch + 1 ))
    ;;
esac

pre_release=""
if [[ -z "$(git rev-parse --abbrev-ref HEAD | grep -e main -e master)" ]]; then
  if [[ -n "$pr_number" ]] && [[ "$pr_number" != "none" ]]; then
    pre_release="-pr$pr_number"
  fi
fi

echo "$major.$minor.${patch}${pre_release}"
