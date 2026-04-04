#!/bin/bash
# List all PostgresServer resources and their states.
#
# Usage:
#   list-postgres-resources.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

json=$("$SCRIPT_DIR/invoke_ubicloud_api_curl.sh" GET /project/default/location/aws-us-west-2/postgres)

strand_labels=$(cd "$PROJECT_ROOT" && bundle exec ruby -e "
require_relative 'loader'
PostgresServer.all.each do |s|
  res = s.resource
  role = s.primary? ? 'primary' : 'replica'
  label = s.strand&.label || 'n/a'
  puts \"#{res.name}\t#{role}\t#{label}\"
end
")

echo "$json" | python3 -c "
import json, sys

data = json.load(sys.stdin)
items = data.get('items', data) if isinstance(data, dict) else data

if not items:
    print('No PostgreSQL resources found.')
    sys.exit(0)

strand_lines = '''$strand_labels'''.strip().splitlines()
labels = {}
for line in strand_lines:
    if not line.strip():
        continue
    parts = line.split('\t')
    name, role, label = parts[0], parts[1], parts[2]
    labels.setdefault(name, []).append(f'{role}={label}')

print(f\"{'NAME':<30} {'STATE':<15} {'SIZE':<15} {'HA':<8} {'VERSION':<10} {'NEXUS LABELS'}\")
print('-' * 110)
for r in items:
    nexus = ', '.join(labels.get(r['name'], []))
    print(f\"{r['name']:<30} {r['state']:<15} {r.get('vm_size',''):<15} {r.get('ha_type',''):<8} {r.get('version',''):<10} {nexus}\")
"
