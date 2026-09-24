#!/bin/bash
# Push the spike scripts to an ember host.
set -euo pipefail
HOST=${1:?usage: sync.sh <host>}
HERE=$(cd "$(dirname "$0")" && pwd)
ssh "root@$HOST" mkdir -p /root/ember_spikes
# --delete keeps the host's copy exact, but never for out/: that is where
# the runs write their results.
rsync -a --delete --exclude /out/ "$HERE/" "root@$HOST:/root/ember_spikes/"
echo "synced to root@$HOST:/root/ember_spikes"
