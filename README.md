# FragJam PMTU and reassembly-pressure lab (isolated Linux namespaces)

This lab creates a WireGuard VPN between `fj-client` and `fj-server`, with
`fj-router` between them. The physical links keep their normal 1500-byte MTU.
A bounded injector fabricates one or more IPv4 ICMP Destination Unreachable /
Fragmentation Needed messages (Type 3, Code 4) advertising a 552-byte path
MTU to the VPN server. If Linux accepts the message, large WireGuard UDP
replies fragment even though the link MTU has not changed. A second bounded
step creates incomplete fragment queues in the router to test whether this
changes VPN packet loss.

**Boundary:** All traffic stays in disposable `fj-*` namespaces and fixed
private addresses. The ICMP injector runs in `fj-router`, using its server-side
address as the ICMP source; it demonstrates the PMTU-cache and fragmentation
behavior, not an off-path source-spoofing capability. Fragment pressure may
cause loss, but it does not necessarily bring down the WireGuard interface.

## Requirements

Debian/Ubuntu Linux host with root, network namespace support, kernel
WireGuard, and working apt repositories. `setup.sh` installs missing lab
packages with `apt-get` before creating namespaces.

## Run

From this directory, reset any prior lab and start a fresh tunnel:

```bash
sudo bash cleanup.sh
sudo bash setup.sh
```

`setup.sh` checks underlay reachability, waits for the WireGuard handshake,
and confirms large VPN pings work before the PMTU signal. No separate server
process is needed. Run the full baseline, PMTU, pressure, and recovery trial:

```bash
sudo bash run_pressure_trial.sh
```

The trial first requires a clean 10-ping VPN baseline. It then sends the
fabricated ICMP message, checks the server's route cache for `mtu 552`, and
captures a fragmented encrypted reply on `fj-router`'s `veth-r1`. It requires
three large VPN pings to pass before starting pressure. The bounded generator
then sends at most 1600 incomplete datagrams at up to 80 first fragments/s,
while 40 large VPN pings measure packet loss. After the generator stops and
fragment queues expire, 10 more pings check recovery.

To inspect the PMTU signal separately, after setup and a successful baseline:

```bash
sudo ip netns exec fj-router python3 forge_pmtu.py
sudo ip -n fj-server route get 10.200.1.1
sudo bash probe_vpn.sh 10
```

To watch outer IPv4 fragments during a probe or trial, run in another terminal:

```bash
sudo ip netns exec fj-router tcpdump -ni veth-r1 -vv 'ip[6:2] & 0x3fff != 0'
```

The router's reassembly thresholds are 32 KiB low and 64 KiB high, with a
12-second fragment timeout. `IpReasmOKs` and `IpReasmFails` are cumulative
reassembly counts, not VPN success percentages. Compare the trial's baseline,
post-PMTU, pressure, and recovery ping summaries.

## Clean up

```bash
sudo bash cleanup.sh
```

Recreating the namespaces clears the lab's PMTU cache and WireGuard keys.
Reset the lab before another full trial so its baseline uses the original
path MTU.

## Troubleshooting

- If `ip netns add` or `ip link add ... type wireguard` reports `Operation not permitted`, use a Linux VM with namespace and WireGuard kernel support.
- If the underlay ping fails, inspect `ip -n fj-client route` and `ip -n fj-server route`.
- If the VPN handshake fails, inspect `sudo ip netns exec fj-client wg show`, `sudo ip netns exec fj-server wg show`, and the router NAT rule with `sudo ip netns exec fj-router iptables -t nat -L -n -v`.
- If `forge_pmtu.py` reports no `mtu 552`, inspect the server's `net.ipv4.route.min_pmtu`, its learned WireGuard endpoint, and ICMP delivery on `veth-s`. The trial stops rather than attributing unrelated loss to the PMTU signal.
- If PMTU changes but no fragments are captured, inspect `ip -n fj-server route get 10.200.1.1` and the `veth-r1` capture. The trial stops before pressure in this case.
- If pressure shows no added loss, confirm the router's reassembly counters rose; the outcome is timing dependent.
