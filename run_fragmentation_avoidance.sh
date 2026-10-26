#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash run_fragmentation_avoidance.sh' >&2; exit 1; fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
server_pid=
capture_pids=()
capture_files=()
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    for pid in "${capture_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    for file in "${capture_files[@]}"; do rm -f -- "$file"; done
}
trap cleanup EXIT

# Run after setup.sh. A 576-byte underlay and 492-byte tunnel leave 84 bytes
# for encapsulation, more than the 60 bytes WireGuard needs over IPv4.
for spec in 'fj-client veth-c' 'fj-router veth-r2' 'fj-router veth-r1' 'fj-server veth-s'; do
    read -r ns dev <<< "$spec"
    ip -n "$ns" link set dev "$dev" mtu 576
done
ip -n fj-client link set dev wg0 mtu 492
ip -n fj-server link set dev wg0 mtu 492

echo 'Constrained MTUs: underlay=576, WireGuard=492, UDP payload cap=524 bytes'
for spec in 'fj-client veth-c' 'fj-router veth-r2' 'fj-router veth-r1' 'fj-server veth-s' 'fj-client wg0' 'fj-server wg0'; do
    read -r ns dev <<< "$spec"
    ip -n "$ns" -o link show dev "$dev" | awk -v ns="$ns" -v dev="$dev" '{print ns "/" dev ": " $0}'
done

# Capture on both router links. The first sees server output; the second sees
# router output after forwarding and NAT. A fragment on either is a failure.
for dev in veth-r1 veth-r2; do
    file=$(mktemp)
    capture_files+=("$file")
    timeout 20 ip netns exec fj-router tcpdump -U -n -i "$dev" -w "$file" ip >/dev/null 2>&1 &
    capture_pids+=("$!")
done
sleep 1

ip netns exec fj-server python3 "$here/server.py" --once \
    --max-response-size 524 --pmtu-mode omit &
server_pid=$!
sleep 0.3
ip netns exec fj-client python3 -c '
import socket
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(3)
    sock.sendto(b"PING", ("10.200.1.2", 9000))
    response, peer = sock.recvfrom(2048)
    assert peer == ("10.200.1.2", 9000), peer
    assert len(response) == 524 and response.startswith(b"PING"), len(response)
    print(f"UDP response received: {len(response)} payload bytes")
'
wait "$server_pid"
server_pid=

# 464 ICMP bytes + 8 ICMP + 20 inner IPv4 = the configured 492-byte tunnel MTU.
ip netns exec fj-client ping -n -I wg0 -M do -s 464 -c 3 -W 2 -w 7 10.77.0.1
sleep 0.5

for pid in "${capture_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
done
capture_pids=()
for index in 0 1; do
    file=${capture_files[$index]}
    dev=$([[ $index == 0 ]] && echo veth-r1 || echo veth-r2)
    packet_count=$(tcpdump -nn -r "$file" ip 2>/dev/null | wc -l)
    fragment_count=$(tcpdump -nn -r "$file" 'ip[6:2] & 0x3fff != 0' 2>/dev/null | wc -l)
    echo "Router $dev: $packet_count IPv4 packets, $fragment_count IPv4 fragments"
    if (( packet_count == 0 || fragment_count != 0 )); then
        echo "Fragmentation avoidance failed on $dev" >&2
        exit 1
    fi
done
echo 'UDP reply and VPN probes passed without server or gateway fragmentation.'
