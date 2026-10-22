#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
exec python3 "$LAB/scripts/client.py" "$@"
