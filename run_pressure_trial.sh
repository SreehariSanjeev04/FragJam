#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash run_pressure_trial.sh' >&2; exit 1; fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pressure_pid=
cleanup() {
    if [[ -n "$pressure_pid" ]]; then
        kill "$pressure_pid" 2>/dev/null || true
        wait "$pressure_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo 'VPN baseline before pressure:'
if ! bash "$here/probe_vpn.sh" 10; then
    echo 'Baseline has loss. Fix the tunnel before attributing loss to fragment pressure.' >&2
    exit 1
fi
echo 'WireGuard state before trial:'
ip netns exec fj-client wg show wg0 latest-handshakes
ip netns exec fj-client wg show wg0 transfer
echo 'Router counters before trial:'
ip netns exec fj-router nstat -az IpReasmReqds IpReasmOKs IpReasmFails
ip netns exec fj-client python3 "$here/fragment_pressure.py" &
pressure_pid=$!
sleep 1
echo 'VPN ping result during pressure:'
if bash "$here/probe_vpn.sh" 40; then
    echo 'All VPN probes received replies.'
else
    echo 'VPN probe reported loss; compare its packet-loss summary with the baseline.'
fi
wait "$pressure_pid"
pressure_pid=
echo 'Router counters after trial:'
ip netns exec fj-router nstat -az IpReasmReqds IpReasmOKs IpReasmFails
echo 'WireGuard state after trial:'
ip netns exec fj-client wg show wg0 latest-handshakes
ip netns exec fj-client wg show wg0 transfer
echo 'Waiting for incomplete fragment queues to expire before recovery check:'
sleep 13
echo 'VPN recovery check:'
if bash "$here/probe_vpn.sh" 10; then
    echo 'VPN probes recovered.'
else
    echo 'VPN still has loss after the pressure generator stopped.'
fi
