#!/bin/bash
# TCP_NODELAY and the concurrent dial, measured separately: four ubiblk
# builds in a 2x2 (stock, nodelay only, dial only, both), interleaved by build
# so drift lands evenly. UBIBLK_DIR is set explicitly for every run.
#
#   bash exp_nodelay_dial.sh [m1] [m2] [m3]     (default: all three)
set -uo pipefail
cd "$(dirname "$0")"
declare -A DIR=(
  [stock]=/opt/vhost-block-backend/v0.5.1
  [nodelay]=/opt/vhost-block-backend/v0.5.1-nodelay
  [dial]=/opt/vhost-block-backend/v0.5.1-dial
  [both]=/opt/vhost-block-backend/v0.5.1-patched
)
PARTS=${*:-m1 m2 m3}
log() { echo "[$(date -u +%FT%TZ)] $*"; }

if [[ $PARTS == *m1* ]]; then
  for n in 1 2 3 4 5; do
    for b in stock nodelay dial both; do
      log "m1 $b sweep $n UBIBLK_DIR=${DIR[$b]}"
      UBIBLK_DIR=${DIR[$b]} RUN_TAG=${b}_${n} ruby probe_remote_connections.rb 1 4 16 32 | tail -4
    done
  done
fi

if [[ $PARTS == *m2* ]]; then
  for n in 1 2 3 4 5; do
    for b in nodelay both; do
      log "m2 $b run $n UBIBLK_DIR=${DIR[$b]}"
      UBIBLK_DIR=${DIR[$b]} ruby s3_transfer.rb t512 200 false > out/s3_transfer_${b}_${n}.log 2>&1
      cp out/s3_transfer.json out/s3_transfer_${b}_${n}.json
      grep -o '"first_query": [0-9.]*' out/s3_transfer_${b}_${n}.json | head -2 | tail -1
    done
  done
fi

if [[ $PARTS == *m3* ]]; then
  for delay in 250us 1ms; do
    bash rtt_link.sh up $delay | tee out/rtt_${delay}.txt
    for n in 1 2 3 4 5; do
      for b in nodelay both; do
        log "m3 $delay $b sweep $n UBIBLK_DIR=${DIR[$b]}"
        UBIBLK_DIR=${DIR[$b]} SERVER_NETNS=clrtt SERVER_ADDRESS=10.253.0.2 RUN_TAG=rtt${delay}_${b}_${n} \
          ruby probe_remote_connections.rb 16 | tail -1
      done
    done
    bash rtt_link.sh down
  done
fi
log done
