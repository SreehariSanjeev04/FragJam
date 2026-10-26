#!/usr/bin/env python3
"""Record bounded FragJam trial observations as JSON lines."""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

NAMESPACES = ("fj-client", "fj-router", "fj-server")
COUNTERS = ("ReasmTimeout", "ReasmReqds", "ReasmOKs", "ReasmFails",
            "FragOKs", "FragFails", "FragCreates")


def local_stats():
    with open("/proc/net/snmp", encoding="ascii") as stream:
        lines = [line.split() for line in stream if line.startswith("Ip:")]
    if len(lines) != 2:
        raise RuntimeError("IPv4 SNMP counters unavailable")
    ip = dict(zip(lines[0][1:], map(int, lines[1][1:])))
    if any(name not in ip for name in COUNTERS):
        raise RuntimeError("Required IPv4 reassembly counters unavailable")
    with open("/proc/net/sockstat", encoding="ascii") as stream:
        frag = next((line.split() for line in stream if line.startswith("FRAG:")), None)
    fields = dict(zip(frag[1::2], map(int, frag[2::2]))) if frag else {}
    devices = {}
    with open("/proc/net/dev", encoding="ascii") as stream:
        for line in list(stream)[2:]:
            name, values = line.split(":", 1)
            numbers = list(map(int, values.split()))
            devices[name.strip()] = {
                "rx_packets": numbers[1], "rx_dropped": numbers[3],
                "tx_packets": numbers[9], "tx_dropped": numbers[11],
            }
    return {
        "ip": {name: ip[name] for name in COUNTERS},
        "frag_queues": fields.get("inuse"),
        "frag_memory_bytes": fields.get("memory"),
        "interfaces": devices,
    }


def namespace_stats(namespace):
    result = subprocess.run(
        ["ip", "netns", "exec", namespace, sys.executable, __file__, "local"],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def append(path, record):
    record["time_utc"] = datetime.now(timezone.utc).isoformat()
    with open(path, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, sort_keys=True) + "\n")


def snapshot(path, stage):
    nodes = {namespace: namespace_stats(namespace) for namespace in NAMESPACES}
    record = {"event": "snapshot", "stage": stage, "nodes": nodes}
    append(path, record)
    print(f"{stage}: " + "; ".join(
        f"{name} reasm(req/ok/fail/timeout)="
        f"{stats['ip']['ReasmReqds']}/{stats['ip']['ReasmOKs']}/"
        f"{stats['ip']['ReasmFails']}/{stats['ip']['ReasmTimeout']} "
        f"frag(queues/bytes)={stats['frag_queues']}/{stats['frag_memory_bytes']}"
        for name, stats in nodes.items()), flush=True)
    return nodes


def record_probe(path, stage, ping_file):
    with open(ping_file, encoding="utf-8", errors="replace") as stream:
        output = stream.read()
    match = re.search(
        r"(\d+) packets transmitted, (\d+) received, ([\d.]+)% packet loss", output
    )
    if not match:
        raise RuntimeError(f"No ping delivery summary in {ping_file}")
    sent, received, loss = match.groups()
    timeout_reports = len(re.findall(r"^no answer yet for icmp_seq=", output, re.M))
    record = {"event": "probe", "stage": stage, "sent": int(sent),
              "received": int(received), "loss_percent": float(loss),
              "timeout_reports": timeout_reports}
    append(path, record)
    print(f"{stage} delivery: {received}/{sent}; loss={loss}%; "
          f"timeout reports={timeout_reports}", flush=True)


def summarize(path):
    with open(path, encoding="utf-8") as stream:
        records = [json.loads(line) for line in stream]
    snapshots = [item for item in records if item["event"] == "snapshot"]
    before = next(item for item in snapshots if item["stage"] == "before_pressure")
    after = next(item for item in snapshots if item["stage"] == "after_pressure")
    pressure = [item for item in snapshots if item["stage"] == "pressure"]
    if not pressure:
        raise RuntimeError("No pressure samples were recorded")
    print("Pressure-window reassembly deltas and peak fragment memory:")
    for name in NAMESPACES:
        old, new = before["nodes"][name], after["nodes"][name]
        delta = {key: new["ip"][key] - old["ip"][key] for key in COUNTERS[:4]}
        memory = [item["nodes"][name]["frag_memory_bytes"] for item in pressure]
        memory = [value for value in memory if value is not None]
        peak = max(memory) if memory else "unavailable"
        print(f"  {name}: {delta}; peak fragment memory={peak} bytes")
        for interface in sorted(set(old["interfaces"]) & set(new["interfaces"])):
            if interface == "lo":
                continue
            change = {key: new["interfaces"][interface][key] - old["interfaces"][interface][key]
                      for key in ("rx_packets", "rx_dropped", "tx_packets", "tx_dropped")}
            print(f"    {interface} packet counters: {change}")
    probes = [item for item in records if item["event"] == "probe"]
    for item in probes:
        print(f"  {item['stage']} delivery: {item['received']}/{item['sent']}")


def assert_state(path, command):
    nodes = snapshot(path, command)
    busy = [name for name, value in nodes.items()
            if value["frag_queues"] is not None and value["frag_queues"] != 0]
    if busy:
        raise RuntimeError(f"fragment queues remain in {', '.join(busy)}")
    if command == "assert-reset":
        dirty = [name for name, value in nodes.items()
                 if any(value["ip"][key] != 0 for key in COUNTERS[:4])]
        if dirty:
            raise RuntimeError(f"reassembly counters are not fresh in {', '.join(dirty)}")
        route = subprocess.run(
            ["ip", "-n", "fj-server", "route", "get", "10.200.1.1"],
            check=True, capture_output=True, text=True,
        ).stdout
        if re.search(r"\bmtu\s+552\b", route):
            raise RuntimeError("server still has the trial PMTU cache entry")
        append(path, {"event": "reset_verified", "route": route.strip()})
        print("Fresh namespace counters, empty fragment queues, and no trial PMTU confirmed.")
    else:
        print("Fragment queues drained after the pressure trial.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("local")
    for command in ("snapshot", "watch", "probe", "assert-reset", "assert-recovered", "summary"):
        item = sub.add_parser(command)
        item.add_argument("--output", required=True)
        if command in ("snapshot", "watch", "probe"):
            item.add_argument("--stage", required=True)
        if command == "probe":
            item.add_argument("--file", required=True)
    args = parser.parse_args()
    if args.command == "local":
        print(json.dumps(local_stats()))
    elif args.command == "snapshot":
        snapshot(args.output, args.stage)
    elif args.command == "watch":
        # A caller-owned process lifetime keeps sampling inside the trial window.
        while True:
            snapshot(args.output, args.stage)
            time.sleep(1)
    elif args.command == "probe":
        record_probe(args.output, args.stage, args.file)
    elif args.command == "summary":
        summarize(args.output)
    else:
        assert_state(args.output, args.command)


if __name__ == "__main__":
    main()
