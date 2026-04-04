#!/bin/bash
# Rsyncs a rhizome file (or the entire rhizome directory) to a postgres VM.
#
# Usage:
#   rsync-rhizome.sh <ssh-key> <ip> [relative-rhizome-path]
#
#   <ssh-key>              Path to SSH private key (e.g. /tmp/pg_ssh_key_myserver)
#   <ip>                   VM IP address
#   [relative-rhizome-path] Optional path relative to rhizome/ to sync a single file.
#                          If omitted, syncs the entire rhizome/ directory.
#
# Examples:
#   rsync-rhizome.sh /tmp/pg_ssh_key_myserver 1.2.3.4
#   rsync-rhizome.sh /tmp/pg_ssh_key_myserver 1.2.3.4 postgres/bin/initialize-empty-database

set -e

KEY="${1:?Usage: rsync-rhizome.sh <ssh-key> <ip> [relative-rhizome-path]}"
IP="${2:?Usage: rsync-rhizome.sh <ssh-key> <ip> [relative-rhizome-path]}"
REL_PATH="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [ -n "$REL_PATH" ]; then
  # rsync may not be available; fall back to scp-via-ssh-stdin
  if command -v rsync &>/dev/null; then
    rsync -e "ssh $SSH_OPTS" \
      "$PROJECT_ROOT/rhizome/$REL_PATH" \
      "ubi@$IP:/home/ubi/$REL_PATH"
  else
    ssh $SSH_OPTS ubi@$IP "cat > /home/ubi/$REL_PATH" < "$PROJECT_ROOT/rhizome/$REL_PATH"
  fi
  echo "Synced rhizome/$REL_PATH to $IP"
else
  if command -v rsync &>/dev/null; then
    rsync -rlpt --delete -e "ssh $SSH_OPTS" \
      "$PROJECT_ROOT/rhizome/" \
      "ubi@$IP:/home/ubi/"
  else
    # tar pipe fallback when rsync is unavailable
    tar -C "$PROJECT_ROOT/rhizome" -cf - . | ssh $SSH_OPTS ubi@$IP "tar -C /home/ubi -xf -"
  fi
  echo "Synced entire rhizome/ to $IP"
fi
