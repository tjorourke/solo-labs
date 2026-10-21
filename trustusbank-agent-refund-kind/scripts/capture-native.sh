#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
tools
chain
BANK_USER_TOKEN="$U" BANK_AGENT_TOKEN="$H1" python3 "$LAB/scripts/native_refund.py" "${1:-approval}"
