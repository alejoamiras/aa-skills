#!/usr/bin/env bash
# Runs findings.ts or headroom.ts under bun from this directory: bun loads bunfig.toml, and with it any preload, from
# its working directory, which during an audit is the untrusted tree; --no-env-file keeps that tree's .env out too.
# Usage: run.sh <findings|headroom> <arg>...   (paths absolute: the working directory changes)
set -euo pipefail
case ${1:-} in findings|headroom) ;; *) echo "usage: run.sh <findings|headroom> <arg>..." >&2; exit 2;; esac
cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && exec bun --no-env-file "./$1.ts" "${@:2}"
