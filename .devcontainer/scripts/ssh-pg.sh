#!/bin/bash
# SSH into a PostgreSQL server VM by resource name.
#
# Usage: ./ssh-pg.sh <resource-name> [server-index]
#   resource-name: Name of the PostgresResource
#   server-index:  0-based index if multiple servers (default: 0)

set -euo pipefail

RESOURCE_NAME="${1:?Usage: ssh-pg.sh <resource-name> [server-index]}"
SERVER_INDEX="${2:-0}"
KEY_FILE="/tmp/pg_ssh_key_$$"

cleanup() { rm -f "$KEY_FILE"; }
trap cleanup EXIT

SSH_INFO=$(RACK_ENV=development bundle exec ruby -r ./loader -e '
  r = PostgresResource.first(name: ARGV[0]) or abort "Resource not found: #{ARGV[0]}"
  s = r.servers[ARGV[1].to_i]&.vm&.sshable or abort "Server or sshable not found at index #{ARGV[1]}"
  File.write(ARGV[2], s.keys.first.private_key)
  File.chmod(0600, ARGV[2])
  puts "#{s.unix_user}@#{s.host}"
' -- "$RESOURCE_NAME" "$SERVER_INDEX" "$KEY_FILE")

echo "Connecting to ${SSH_INFO}..."
ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_INFO"
