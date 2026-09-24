#!/bin/bash
# Tear down everything the spikes leave behind.
set -uo pipefail
pkill -f '/opt/cloud-hypervisor/v53.0/cloud-hypervisor' 2>/dev/null
pkill -f '/opt/vhost-block-backend/.*/vhost-backend' 2>/dev/null
pkill -f 'remote-stripe-server' 2>/dev/null
sleep 0.5
for ns in $(ip netns list 2>/dev/null | awk '{print $1}' | grep '^emslot'); do
  ip netns del "$ns" 2>/dev/null
done
for l in $(ip -br link 2>/dev/null | awk '{print $1}' | grep -E '^vetho[0-9]+' | cut -d@ -f1); do
  ip link del "$l" 2>/dev/null
done
rm -rf /vm/emslot* 2>/dev/null
if [[ "${1:-}" == "--volumes" ]]; then
  rm -rf /var/storage/detachable/* 2>/dev/null
  echo "volumes removed"
fi
echo "cleaned up"
