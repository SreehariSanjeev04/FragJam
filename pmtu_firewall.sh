#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    echo 'Run: sudo bash pmtu_firewall.sh {enable|disable|show}' >&2
    exit 1
fi

chain=FJ_PTB_VALIDATE
iptables_ns() { ip netns exec fj-server iptables -w "$@"; }

case "${1:-}" in
    enable)
        # Only ICMP Fragmentation Needed packets enter this chain. Install the
        # jump first so an existing broad RELATED accept cannot bypass it.
        if ! iptables_ns -nL "$chain" >/dev/null 2>&1; then
            iptables_ns -N "$chain"
        fi
        iptables_ns -F "$chain"
        iptables_ns -A "$chain" -i veth-s -s 10.200.1.1 -d 10.200.1.2 \
            -m conntrack --ctstate RELATED --ctstatus SEEN_REPLY \
            --ctproto udp --ctorigsrc 10.200.1.1 --ctorigdst 10.200.1.2 \
            --ctorigdstport 51820 --ctreplsrc 10.200.1.2 \
            --ctrepldst 10.200.1.1 --ctreplsrcport 51820 -j ACCEPT
        iptables_ns -A "$chain" -j DROP
        if ! iptables_ns -C INPUT -p icmp --icmp-type 3/4 -j "$chain" 2>/dev/null; then
            iptables_ns -I INPUT 1 -p icmp --icmp-type 3/4 -j "$chain"
        fi
        echo 'Server PTB validation enabled.'
        ;;
    disable)
        if iptables_ns -nL "$chain" >/dev/null 2>&1; then
            while iptables_ns -C INPUT -p icmp --icmp-type 3/4 -j "$chain" 2>/dev/null; do
                iptables_ns -D INPUT -p icmp --icmp-type 3/4 -j "$chain"
            done
            iptables_ns -F "$chain"
            iptables_ns -X "$chain"
        fi
        echo 'Server PTB validation disabled.'
        ;;
    show)
        iptables_ns -nvL "$chain"
        ;;
    *)
        echo 'Usage: sudo bash pmtu_firewall.sh {enable|disable|show}' >&2
        exit 2
        ;;
esac
