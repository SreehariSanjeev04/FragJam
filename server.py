#!/usr/bin/env python3
"""Bounded IPv4 UDP responder for the optional packet-sizing experiment."""

import argparse
import errno
import socket
import sys

IPV4_HEADER_BYTES = 20
UDP_HEADER_BYTES = 8
CONSERVATIVE_IPV4_PACKET_BYTES = 576
DEFAULT_MAX_RESPONSE_SIZE = (
    CONSERVATIVE_IPV4_PACKET_BYTES - IPV4_HEADER_BYTES - UDP_HEADER_BYTES
)
MAX_UDP_PAYLOAD = 65535 - IPV4_HEADER_BYTES - UDP_HEADER_BYTES
REQUEST_SIZE = 4


def response_size(value):
    size = int(value)
    if not REQUEST_SIZE <= size <= MAX_UDP_PAYLOAD:
        raise argparse.ArgumentTypeError(
            f"size must be between {REQUEST_SIZE} and {MAX_UDP_PAYLOAD} UDP payload bytes"
        )
    return size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=response_size, default=1200,
                        help="requested response payload bytes (default: 1200)")
    parser.add_argument("--max-response-size", type=response_size,
                        default=DEFAULT_MAX_RESPONSE_SIZE,
                        help="UDP response payload cap in bytes (default: 548)")
    parser.add_argument("--pmtu-mode", choices=("omit", "do"), default="omit",
                        help="Linux PMTU socket mode (default: omit)")
    parser.add_argument("--bind-address", default="10.200.1.2")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--once", action="store_true",
                        help="exit after one valid response")
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")

    limit = min(args.size, args.max_response_size)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        # OMIT ignores learned PMTU for this socket. The payload cap must fit
        # the configured egress MTU: OMIT can fragment above that interface MTU.
        # DO is available when strict DF behavior is required instead.
        sock.setsockopt(socket.IPPROTO_IP,
                        getattr(socket, "IP_MTU_DISCOVER", 10),
                        {"omit": 5, "do": 2}[args.pmtu_mode])
        sock.bind((args.bind_address, args.port))
        address, port = sock.getsockname()
        print(f"UDP responder on {address}:{port}; PMTU mode={args.pmtu_mode}; "
              f"response payload={limit} bytes; "
              f"maximum IPv4 packet={limit + IPV4_HEADER_BYTES + UDP_HEADER_BYTES} bytes",
              flush=True)
        while True:
            request, peer = sock.recvfrom(2048)
            if len(request) != REQUEST_SIZE:
                continue
            reply = request + b"X" * (limit - REQUEST_SIZE)
            try:
                sock.sendto(reply, peer)
            except OSError as exc:
                if exc.errno != errno.EMSGSIZE:
                    raise
                print(f"Skipped response to {peer}: {limit + IPV4_HEADER_BYTES + UDP_HEADER_BYTES}-byte "
                      "IPv4 packet exceeds the usable MTU",
                      file=sys.stderr, flush=True)
                continue
            if args.once:
                return


if __name__ == "__main__":
    main()
