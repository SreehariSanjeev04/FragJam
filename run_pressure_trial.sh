#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash run_pressure_trial.sh' >&2; exit 1; fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$here/results"
run_dir=$(mktemp -d "$here/results/trial-XXXXXXXX")
events="$run_dir/observations.jsonl"
pressure_pid=
capture_pid=
monitor_pid=
cleanup_processes() {
    for pid in "$pressure_pid" "$capture_pid" "$monitor_pid"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup_processes EXIT

snapshot() {
    python3 "$here/monitor_reassembly.py" snapshot --output "$events" --stage "$1"
}
probe() {
    local stage=$1 count=$2 result=0
    bash "$here/probe_vpn.sh" "$count" > "$run_dir/$stage.ping.txt" 2>&1 || result=$?
    cat "$run_dir/$stage.ping.txt"
    python3 "$here/monitor_reassembly.py" probe --output "$events" \
        --stage "$stage" --file "$run_dir/$stage.ping.txt"
    return "$result"
}

echo "Trial records: $run_dir"
echo 'Resetting disposable namespaces for this run:'
bash "$here/cleanup.sh"
for ns in fj-client fj-router fj-server; do
    if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
        echo "Namespace $ns remained after cleanup; refusing a mixed-state run." >&2
        exit 1
    fi
done
bash "$here/setup.sh"
python3 "$here/monitor_reassembly.py" assert-reset --output "$events"

echo 'VPN baseline before pressure:'
if ! probe baseline 10; then
    echo 'Baseline has loss. Fix the tunnel before attributing loss to fragment pressure.' >&2
    exit 1
fi
snapshot baseline

echo 'Sending fabricated ICMP Fragmentation Needed to the VPN server:'
ip netns exec fj-router python3 "$here/forge_pmtu.py"
snapshot post_pmtu
echo 'Verifying large VPN packets still pass and encrypted replies fragment:'
timeout 8 ip netns exec fj-router tcpdump -nn -i veth-r1 -c 1 \
    'src host 10.200.1.2 and (ip[6:2] & 0x3fff != 0)' \
    > "$run_dir/fragments.capture.txt" 2>&1 &
capture_pid=$!
sleep 0.5
if ! probe post_pmtu 3; then
    echo 'VPN probe failed after PMTU signal, before fragment pressure.' >&2
    exit 1
fi
if ! wait "$capture_pid"; then
    cat "$run_dir/fragments.capture.txt" >&2
    echo 'No fragmented server WireGuard packet was captured; stopping trial.' >&2
    exit 1
fi
capture_pid=
cat "$run_dir/fragments.capture.txt"
snapshot before_pressure

echo 'Sampling reassembly and fragment memory once per second during pressure.'
python3 "$here/monitor_reassembly.py" watch --output "$events" \
    --stage pressure > "$run_dir/monitor.log" 2>&1 &
monitor_pid=$!
timeout 45 ip netns exec fj-client python3 "$here/fragment_pressure.py" \
    --report "$run_dir/attacker.json" > "$run_dir/attacker.log" 2>&1 &
pressure_pid=$!
sleep 1
echo 'VPN ping result during pressure:'
if probe pressure 40; then
    echo 'All VPN probes received replies.'
else
    echo 'VPN probe reported loss; compare its packet-loss summary with the baseline.'
fi
if ! wait "$pressure_pid"; then
    cat "$run_dir/attacker.log" >&2
    echo 'Pressure generator failed or exceeded the 45-second trial limit.' >&2
    exit 1
fi
pressure_pid=
if ! kill -0 "$monitor_pid" 2>/dev/null; then
    cat "$run_dir/monitor.log" >&2
    echo 'Reassembly sampler stopped during pressure.' >&2
    exit 1
fi
kill "$monitor_pid" 2>/dev/null || true
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=
cat "$run_dir/attacker.log"
cat "$run_dir/attacker.json" >> "$events"
snapshot after_pressure

echo 'WireGuard endpoint delivery totals:'
ip netns exec fj-client wg show wg0 transfer | tee "$run_dir/wg-transfer.txt"
echo 'Waiting 13 seconds for incomplete fragment queues to expire:'
sleep 13
python3 "$here/monitor_reassembly.py" assert-recovered --output "$events"
echo 'VPN recovery check:'
if probe recovery 10; then
    echo 'VPN probes recovered.'
else
    echo 'VPN still has loss after the pressure generator stopped.' >&2
    exit 1
fi
snapshot recovery
python3 "$here/monitor_reassembly.py" summary --output "$events"
echo "Trial complete. Records: $run_dir"
