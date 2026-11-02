#!/usr/bin/env bash
# stock-macos.sh [<tool>...] -- <command>...: run a command on a stock macOS PATH (bash 3.2 and the BSD userland in
# /usr/bin, /bin, /usr/sbin, /sbin) plus only the named tools, linked from the caller's PATH. Homebrew's coreutils,
# flock, timeout and bash 5 stay out of reach, so a GNU-only flag or bash 4 syntax fails here as on a fresh Mac.
set -euo pipefail
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
while [ $# -gt 0 ] && [ "$1" != -- ]; do
  p=$(command -v "$1") || { echo "stock-macos: $1 not found" >&2; exit 2; }
  ln -s "$p" "$bin/$1"
  shift
done
[ $# -gt 1 ] || { echo "usage: stock-macos.sh [<tool>...] -- <command>..." >&2; exit 2; }
shift
PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@"
