#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash probe_vpn.sh [count]' >&2; exit 1; fi
count=${1:-40}
if [[ ! "$count" =~ ^([1-9]|[1-9][0-9]|100)$ ]]; then
    echo 'count must be between 1 and 100' >&2
    exit 1
fi

# The ICMP payload crosses wg0. Its encrypted outer WireGuard reply fits the
# underlay before the PMTU signal and fragments after that signal is accepted.
ip netns exec fj-client ping -n -O -I wg0 -M dont -s 1000 \
    -i 0.5 -W 1 -w "$((count / 2 + 5))" -c "$count" 10.77.0.1
