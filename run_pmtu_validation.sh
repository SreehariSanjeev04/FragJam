#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then echo 'Run: sudo bash run_pmtu_validation.sh' >&2; exit 1; fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
counter() {
    ip netns exec fj-server iptables -w -nvxL FJ_PTB_VALIDATE | \
        awk -v target="$1" '$3 == target { print $1; exit }'
}
assert_incremented() {
    local target=$1 before=$2 after
    after=$(counter "$target")
    if [[ ! "$after" =~ ^[0-9]+$ ]] || (( after <= before )); then
        echo "Expected the $target firewall counter to increase (before=$before, after=$after)" >&2
        exit 1
    fi
}

echo 'Enabling server PTB validation:'
bash "$here/pmtu_firewall.sh" enable
echo 'Checking VPN baseline and establishing a tracked bidirectional flow:'
bash "$here/probe_vpn.sh" 3
drop_before=$(counter DROP)
echo 'Testing an Echo Reply quote (must be dropped):'
ip netns exec fj-router python3 "$here/forge_pmtu.py" --case echo-reply
assert_incremented DROP "$drop_before"
drop_before=$(counter DROP)
echo 'Testing an unvalidated UDP client port (must be dropped):'
ip netns exec fj-router python3 "$here/forge_pmtu.py" --case unvalidated-udp-port
assert_incremented DROP "$drop_before"
accept_before=$(counter ACCEPT)
echo 'Testing the validated, bidirectional WireGuard UDP flow (must pass):'
ip netns exec fj-router python3 "$here/forge_pmtu.py" --case valid-udp
assert_incremented ACCEPT "$accept_before"
echo 'Firewall match counters:'
bash "$here/pmtu_firewall.sh" show
echo 'Checking VPN after accepted PMTU feedback:'
bash "$here/probe_vpn.sh" 3
