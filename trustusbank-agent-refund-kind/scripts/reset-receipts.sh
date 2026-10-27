#!/usr/bin/env bash
# Reset only the disposable mock bank's in-memory receipts for a fresh demo.
source "$(dirname "$0")/lib.sh"
printf 'Resetting all synthetic refund receipts on trustusbank-lab. Start new agent chats afterwards.\n'
restart_deployment bank core-bank
k -n bank rollout status deployment/core-bank --timeout=300s
printf 'Synthetic receipts reset. Native approval will be shown again for PAY-7790.\n'
