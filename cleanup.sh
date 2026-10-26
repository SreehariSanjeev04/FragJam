#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash cleanup.sh' >&2; exit 1; fi
for ns in fj-client fj-router fj-server; do
    if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
        ip netns del "$ns"
        echo "Deleted $ns"
    fi
done
echo 'Stopped programs may need Ctrl+C before namespace cleanup.'
