#!/usr/bin/env python3
"""Hard-limited incomplete-fragment probe for the private fj-* namespace lab only.

Never provides destination/rate/count options: target and traffic ceiling are fixed.
"""
import os
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
conf.verb = 0

start = time.monotonic()
print(f'[+0.0s] Sending at most {TOTAL} incomplete datagrams at <=80 packets/s', flush=True)
for i in range(TOTAL):
    datagram = (IP(src=SOURCE, dst=DESTINATION, id=20000 + i) /
                UDP(sport=42000, dport=51820) /
                Raw(b'P' * 1300))
    fragments = fragment(datagram, fragsize=560)
    assert len(fragments) >= 2
    send(fragments[0], verbose=0)
    if (i + 1) % 80 == 0:
        print(f'[+{time.monotonic() - start:.1f}s] Sent {i + 1}/{TOTAL}', flush=True)
    time.sleep(GAP)
print(f'[+{time.monotonic() - start:.1f}s] Finished sending.', flush=True)
