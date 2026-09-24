#!/bin/bash
# The spikes before s14 were measured with a vsock guest agent, which the
# production image no longer has. Layer it back into a copy of the image that
# postgres-vm-images' ember/build.sh produced, for reproducing them:
#
#   cell-root-18-agent.raw          the agent runs PostgreSQL rather than the
#                                   data disk's hot-plug
#   cell-pgdata-18-nojournal.raw    what s9_crash_safety.rb compares against
#
# Re-run after changing guest/ember-agent.
set -euo pipefail
IMAGES=${IMAGES:-/var/storage/ember/images}
HERE=$(cd "$(dirname "$0")" && pwd)
MNT=/mnt/emberagent
mkdir -p $MNT

cp --sparse=always "$IMAGES/cell-root-18.raw" "$IMAGES/cell-root-18-agent.raw.tmp"
LOOP=$(losetup -f --show -P "$IMAGES/cell-root-18-agent.raw.tmp")
trap 'mountpoint -q $MNT && umount $MNT; losetup -d "$LOOP"' EXIT
for i in $(seq 50); do [[ -e "${LOOP}p1" ]] && break; partx -u "$LOOP" 2>/dev/null || true; sleep 0.2; done
mount "${LOOP}p1" $MNT
install -m 0755 "$HERE/guest/ember-agent" $MNT/usr/local/bin/ember-agent
install -m 0644 "$HERE/guest/ember-agent.service" $MNT/etc/systemd/system/ember-agent.service
mkdir -p $MNT/etc/systemd/system/basic.target.wants
ln -sf /etc/systemd/system/ember-agent.service $MNT/etc/systemd/system/basic.target.wants/ember-agent.service
# The agent reseeds, mounts the disk and starts PostgreSQL itself; left in
# place, systemd would take the agent's mount of /data for data.mount.
rm -f $MNT/etc/udev/rules.d/90-ember-data.rules $MNT/etc/systemd/system/data.mount \
  $MNT/etc/systemd/system/ember-restore-hook.service $MNT/etc/systemd/system/cell-postgres.service
rm -rf "$MNT/etc/systemd/system/systemd-fsck@dev-disk-by\x2did-virtio\x2dcldata.service.d"
sync
umount $MNT
losetup -d "$LOOP"
trap - EXIT
mv "$IMAGES/cell-root-18-agent.raw.tmp" "$IMAGES/cell-root-18-agent.raw"

cp --sparse=always "$IMAGES/cell-pgdata-18.raw" "$IMAGES/cell-pgdata-18-nojournal.raw"
tune2fs -O ^has_journal "$IMAGES/cell-pgdata-18-nojournal.raw" >/dev/null
echo "built cell-root-18-agent.raw and cell-pgdata-18-nojournal.raw in $IMAGES"
