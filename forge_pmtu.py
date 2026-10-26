#!/usr/bin/env python3
"""One bounded ICMP Fragmentation Needed signal for this lab's WireGuard peer.

Run only inside fj-router. The quoted UDP flow is derived from fj-server's
authenticated WireGuard endpoint; no destination or MTU is user-configurable.
"""
import os
import re
import subprocess
import time

from scapy.all import ICMP, IP, Raw, UDP, conf, send

ROUTER = "10.200.1.1"
SERVER = "10.200.1.2"
NEXT_HOP_MTU = 552
SERVER_WG_PORT = 51820

if os.stat("/proc/self/ns/net").st_ino != os.stat("/var/run/netns/fj-router").st_ino:
    raise SystemExit("Refusing to run outside the fj-router namespace")

endpoints = subprocess.check_output(
    ["ip", "netns", "exec", "fj-server", "wg", "show", "wg0", "endpoints"],
    text=True,
).strip().splitlines()
if len(endpoints) != 1:
    raise SystemExit("Expected exactly one server WireGuard peer with a learned endpoint")
_, endpoint = endpoints[0].split()
if endpoint == "(none)":
    raise SystemExit("No server peer endpoint yet; establish the VPN first")
host, port_text = endpoint.rsplit(":", 1)
if host != ROUTER or not port_text.isdecimal() or not (1 <= int(port_text) <= 65535):
    raise SystemExit(f"Unexpected server peer endpoint: {endpoint}")

# ICMP quotes the original outer IPv4 header and eight UDP bytes. Build a
# plausible oversized WireGuard datagram so the quote has correct lengths and
# checksums, then include only the part an IPv4 ICMP error needs to quote.
original = bytes(
    IP(src=SERVER, dst=ROUTER, flags="DF")
    / UDP(sport=SERVER_WG_PORT, dport=int(port_text))
    / Raw(b"W" * 1000)
)
quoted_header = original[:28]
signal = (
    IP(src=ROUTER, dst=SERVER)
    / ICMP(type=3, code=4, nexthopmtu=NEXT_HOP_MTU)
    / Raw(quoted_header)
)

def route_state():
    return subprocess.check_output(
        ["ip", "-n", "fj-server", "route", "get", ROUTER], text=True
    ).strip()

before = route_state()
cached_mtu = re.search(r"\bmtu\s+(\d+)\b", before)
if cached_mtu and int(cached_mtu.group(1)) < 1500:
    raise SystemExit(
        f"Server already has a reduced PMTU ({cached_mtu.group(1)}); "
        "reset the lab with cleanup.sh and setup.sh before a new trial"
    )
print(f"Server endpoint: {endpoint}; advertised PMTU: {NEXT_HOP_MTU}", flush=True)
print(f"Route before: {before}", flush=True)
conf.verb = 0
for attempt in range(1, 4):
    send(signal, verbose=0)
    time.sleep(0.3)
    state = route_state()
    if re.search(r"\bmtu\s+552\b", state):
        print(f"Route after attempt {attempt}: {state}", flush=True)
        break
else:
    raise SystemExit(f"PMTU 552 was not observed after three signals. Route: {state}")
