#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash setup.sh' >&2; exit 1; fi

# Install lab tools only when something is missing. apt-get skips packages that
# are already installed; the kernel must still provide network namespaces and
# WireGuard support.
need_packages=0
for cmd in ip iptables sysctl wg ping nstat tcpdump python3 mktemp timeout; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        need_packages=1
        break
    fi
done
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import scapy.all' >/dev/null 2>&1; then
    need_packages=1
fi
if (( need_packages )); then
    if ! command -v apt-get >/dev/null 2>&1; then
        echo 'Missing lab dependencies. Automatic installation requires Debian/Ubuntu apt-get.' >&2
        exit 1
    fi
    echo 'Installing missing lab dependencies with apt-get...'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        iproute2 iptables iputils-ping tcpdump wireguard-tools \
        python3 python3-scapy conntrack procps coreutils
fi
for cmd in ip iptables sysctl wg ping nstat tcpdump python3 mktemp timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing $cmd after installation" >&2; exit 1; }
done
python3 -c 'import scapy.all' >/dev/null 2>&1 || {
    echo 'Python cannot import Scapy after installation; check which python3 is on PATH.' >&2
    exit 1
}
for ns in fj-client fj-router fj-server; do
    if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
        echo "Namespace $ns already exists. Run sudo bash cleanup.sh first." >&2
        exit 1
    fi
done

# Keys exist on disk only while this script configures the two disposable peers.
umask 077
keydir=$(mktemp -d)
trap 'rm -rf -- "$keydir"' EXIT
wg genkey > "$keydir/client.key"
wg genkey > "$keydir/server.key"
client_public=$(wg pubkey < "$keydir/client.key")
server_public=$(wg pubkey < "$keydir/server.key")

ip netns add fj-client
ip netns add fj-router
ip netns add fj-server
ip link add veth-c type veth peer name veth-r2
ip link add veth-s type veth peer name veth-r1
ip link set veth-c netns fj-client
ip link set veth-r2 netns fj-router
ip link set veth-s netns fj-server
ip link set veth-r1 netns fj-router

ip -n fj-client address add 10.200.2.2/24 dev veth-c
ip -n fj-router address add 10.200.2.1/24 dev veth-r2
ip -n fj-server address add 10.200.1.2/24 dev veth-s
ip -n fj-router address add 10.200.1.1/24 dev veth-r1

for ns in fj-client fj-router fj-server; do ip -n "$ns" link set lo up; done
ip -n fj-client link set veth-c up
ip -n fj-router link set veth-r2 up
ip -n fj-server link set veth-s up
ip -n fj-router link set veth-r1 up

ip -n fj-client route add default via 10.200.2.1
ip -n fj-server route add default via 10.200.1.1
ip netns exec fj-router sysctl -q -w net.ipv4.ip_forward=1

# Force server UDP replies to fragment. These settings affect only the lab interfaces.
ip -n fj-server link set veth-s mtu 600
ip -n fj-router link set veth-r1 mtu 600

# Invoke conntrack-based defragmentation on the gateway.
ip netns exec fj-router iptables -t nat -A POSTROUTING \
    -s 10.200.2.0/24 -o veth-r1 -j MASQUERADE

# The tunnel endpoints are on opposite sides of the router. The server learns
# the client's NAT address from its authenticated WireGuard handshake.
ip -n fj-client link add wg0 type wireguard
ip -n fj-server link add wg0 type wireguard
ip netns exec fj-client wg set wg0 listen-port 51821 \
    private-key "$keydir/client.key" \
    peer "$server_public" allowed-ips 10.77.0.1/32 \
    endpoint 10.200.1.2:51820 persistent-keepalive 5
ip netns exec fj-server wg set wg0 listen-port 51820 \
    private-key "$keydir/server.key" \
    peer "$client_public" allowed-ips 10.77.0.2/32
ip -n fj-client address add 10.77.0.2/24 dev wg0
ip -n fj-server address add 10.77.0.1/24 dev wg0
# A 1000-byte ICMP payload fits this tunnel MTU but makes the encrypted
# outer IPv4/UDP datagram exceed the 600-byte server-side link MTU.
ip -n fj-client link set dev wg0 mtu 1180 up
ip -n fj-server link set dev wg0 mtu 1180 up

# Keep incomplete queues within a small, disposable namespace budget. The
# generator's first fragments cannot reach the usual 4 MiB default.
# The kernel requires low_thresh <= high_thresh, so lower the default 3 MiB
# low threshold first. Both sysctls are scoped to fj-router.
ip netns exec fj-router sysctl -q -w net.ipv4.ipfrag_low_thresh=32768
ip netns exec fj-router sysctl -q -w net.ipv4.ipfrag_high_thresh=65536
ip netns exec fj-router sysctl -q -w net.ipv4.ipfrag_time=12

echo 'Lab ready. Addresses:'
echo '  client 10.200.2.2 (fj-client)'
echo '  router 10.200.2.1 / 10.200.1.1 (fj-router)'
echo '  server 10.200.1.2 (fj-server)'
echo '  WireGuard tunnel: client 10.77.0.2 -> server 10.77.0.1'
ip netns exec fj-router sysctl net.ipv4.ipfrag_low_thresh net.ipv4.ipfrag_high_thresh net.ipv4.ipfrag_time
echo 'Checking underlay connectivity:'
ip netns exec fj-client ping -c 2 -W 1 10.200.1.2
echo 'Waiting for WireGuard handshake with small packets:'
handshake_ready=0
for attempt in {1..10}; do
    if ip netns exec fj-client ping -n -I wg0 -c 1 -W 1 10.77.0.1 >/dev/null 2>&1; then
        handshake_ready=1
        echo "  Tunnel replied on attempt $attempt/10"
        break
    fi
    sleep 1
done
if (( handshake_ready == 0 )); then
    echo 'Small tunnel packets still fail after retries; WireGuard handshake/routing is not working.' >&2
    ip netns exec fj-client wg show wg0
    ip netns exec fj-server wg show wg0
    ip netns exec fj-router iptables -t nat -L POSTROUTING -n -v
    exit 1
fi
echo 'Checking WireGuard tunnel with fragmented outer UDP packets:'
if ! ip netns exec fj-client ping -n -I wg0 -M dont -s 1000 -c 3 -W 2 -w 7 10.77.0.1; then
    echo 'Large tunnel packets failed before pressure; inspect outer fragments on veth-r1.' >&2
    ip netns exec fj-client wg show wg0
    ip netns exec fj-server wg show wg0
    ip netns exec fj-router nstat -az IpReasmReqds IpReasmOKs IpReasmFails
    exit 1
fi
echo 'Tunnel ready. Run sudo bash probe_vpn.sh for a longer baseline.'
