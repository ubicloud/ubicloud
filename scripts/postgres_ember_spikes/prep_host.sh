#!/bin/bash
# One-off host preparation for the ember spikes.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# A psql client on the host lets the spikes talk to an ember the way the
# gateway will, from inside the slot's namespace.
if ! command -v psql >/dev/null; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  . /etc/os-release
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends postgresql-client-18
fi

# Ember VMs use shared=on (fd-backed, non-hugepage) memory, so an ember host
# must not park all of its RAM in the 1 GiB hugepage pool the way a normal
# Ubicloud VM host does.
if [[ $(cat /proc/sys/vm/nr_hugepages) -gt 32 ]]; then
  echo "shrinking hugepage pool so ember VMs have memory to run in"
  sysctl -w vm.nr_hugepages=16
fi

# memory_restore_mode=ondemand needs userfaultfd. The default Ubuntu policy
# restricts it to root; cloud-hypervisor runs as the per-slot unix user.
sysctl -w vm.unprivileged_userfaultfd=1 >/dev/null
chmod 0666 /dev/userfaultfd 2>/dev/null || true

mkdir -p /var/storage/ember/{images,templates,work} /var/storage/detachable /vm /root/ember_spikes/out
echo "host prepared"
