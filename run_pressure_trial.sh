#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash run_pressure_trial.sh' >&2; exit 1; fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pressure_pid=
capture_pid=
capture_file=
cleanup() {
    if [[ -n "$pressure_pid" ]]; then
        kill "$pressure_pid" 2>/dev/null || true
        wait "$pressure_pid" 2>/dev/null || true
    fi
    if [[ -n "$capture_pid" ]]; then
        kill "$capture_pid" 2>/dev/null || true
        wait "$capture_pid" 2>/dev/null || true
    fi
    if [[ -n "$capture_file" ]]; then rm -f -- "$capture_file"; fi
}
trap cleanup EXIT

echo 'VPN baseline before pressure:'
if ! bash "$here/probe_vpn.sh" 10; then
    echo 'Baseline has loss. Fix the tunnel before attributing loss to fragment pressure.' >&2
    exit 1
fi
echo 'Sending fabricated ICMP Fragmentation Needed to the VPN server:'
ip netns exec fj-router python3 "$here/forge_pmtu.py"
echo 'Verifying large VPN packets still pass and encrypted replies fragment:'
capture_file=$(mktemp)
timeout 8 ip netns exec fj-router tcpdump -nn -i veth-r1 -c 1 \
    'src host 10.200.1.2 and (ip[6:2] & 0x3fff != 0)' \
    > "$capture_file" 2>&1 &
capture_pid=$!
sleep 0.5
if ! bash "$here/probe_vpn.sh" 3; then
    echo 'VPN probe failed after PMTU signal, before fragment pressure.' >&2
    exit 1
fi
if ! wait "$capture_pid"; then
    cat "$capture_file" >&2
    echo 'No fragmented server WireGuard packet was captured; stopping trial.' >&2
    exit 1
fi
capture_pid=
cat "$capture_file"
rm -f -- "$capture_file"
capture_file=
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
