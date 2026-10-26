#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if (( EUID != 0 )); then
    exec sudo bash "$here/counters.sh"
fi
record=$(mktemp)
trap 'rm -f -- "$record"' EXIT
python3 "$here/monitor_reassembly.py" snapshot --output "$record" --stage manual
