#!/usr/bin/env bash
set -euo pipefail
sudo ip netns exec fj-router nstat -az IpReasmReqds IpReasmOKs IpReasmFails
