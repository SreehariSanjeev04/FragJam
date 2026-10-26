# Fragment pressure against a WireGuard tunnel (isolated namespace lab)

This lab creates a WireGuard VPN between `fj-client` and `fj-server`, with
`fj-router` between them. It measures large ICMP echo requests through the
tunnel while a bounded generator sends incomplete IPv4 fragments through the
router. The server-side underlay link has MTU 600, so large WireGuard packets
are fragmented on that link. Packet loss during the trial demonstrates a
degraded VPN data path; it does not necessarily mean the WireGuard handshake
or interface goes down.

**Boundary:** All addresses and traffic stay in the three disposable Linux
network namespaces. This is a reassembly-pressure demonstration, not the
off-path forged-ICMP portion of FragJam. Loss under pressure is probabilistic.

## Requirements

Ubuntu/Debian Linux host with root, namespace support, kernel WireGuard, and
working apt repositories. `setup.sh` installs missing lab packages with
`apt-get` before creating the namespaces.

## Run

From this directory:

```bash
sudo bash setup.sh
sudo bash probe_vpn.sh 40
```

`setup.sh` creates both WireGuard peers and ephemeral keys. It checks underlay
reachability, small VPN pings with handshake retries, then a large VPN
ping. No separate server process is
needed. `probe_vpn.sh` sends 1000-byte ICMP payloads to `10.77.0.1` through
`wg0`; compare its packet-loss summary before and during pressure. A small
control ping, `sudo ip netns exec fj-client ping -c 3 10.77.0.1`, shows whether
small tunnel packets still pass while large ones are affected.

To watch the fragmented outer packets in another terminal:

```bash
sudo ip netns exec fj-router tcpdump -ni veth-r1 -vv 'ip[6:2] & 0x3fff != 0'
```

Run one timed pressure trial:

```bash
sudo bash run_pressure_trial.sh
```

The trial first requires a clean 10-ping baseline, then prints the client's
WireGuard handshake and transfer state, router reassembly counters, and 40
large VPN pings under pressure. It waits for incomplete fragment queues to
expire before a 10-ping recovery check. The generator sends at most 1600 first
fragments at up to 80 packets/s. The router has a 32 KiB low threshold, 64 KiB
high threshold, and 12-second fragment timeout. Compare packet loss across the
three phases. `IpReasmOKs` and `IpReasmFails` are cumulative reassembly counts,
not VPN success percentages.

## Clean up

```bash
sudo bash cleanup.sh
```

Then run `sudo bash setup.sh` to reset the namespaces, counters, and keys.

## Troubleshooting

- `Operation not permitted` during `ip netns add` or `ip link add ... type wireguard`: run on a Linux VM with namespace and WireGuard kernel support.
- If the setup underlay ping fails, inspect `ip -n fj-client route` and `ip -n fj-server route`.
- If small tunnel pings fail, inspect `sudo ip netns exec fj-client wg show`, `sudo ip netns exec fj-server wg show`, and the router NAT rule with `sudo ip netns exec fj-router iptables -t nat -L -n -v`.
- If small pings pass but 1000-byte pings fail before pressure, inspect fragments on both sides of the router: `sudo ip netns exec fj-router tcpdump -ni veth-r1 -vv 'ip[6:2] & 0x3fff != 0'` and the equivalent capture on `veth-r2`.
- If no fragments appear in the capture, check `ip -n fj-server link show veth-s` for MTU 600 and use the 1000-byte probe payload. The outer WireGuard UDP traffic uses server port 51820.
- A trial may show no added loss. Confirm that fragment counters rose and repeat a fresh baseline and one trial; reassembly pressure is timing dependent.
