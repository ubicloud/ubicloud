---
name: ubicloud-debug
description: Debug stuck or failing Ubicloud resource provisioning. Use when a strand is stuck, crash-looping, or a provision fails to reach the running state.
user-invocable: true
---

# Ubicloud Debug Skill

You are debugging a stuck or failing Ubicloud resource provisioning. Always run commands from the current project root.

## Strand / Nexus Basics

The control plane uses a strand state machine. Each resource has a `Strand` with a `label` (current step) and `try` (attempt count since last `nap`).

Key fields:
- `strand.label` — current step being executed
- `strand.try` — resets to 0 on `nap`; high values (hundreds+) mean crash-looping
- `strand.lease` — held by the runner while executing; set 2 minutes out normally; set ~1000 years out while a daemonizer job is in progress on the VM
- `strand.schedule` — when it's next eligible to run

### PostgresServerNexus label sequence

```
bootstrap_rhizome → run_init_script → initialize_empty_database
  → configure_metrics → configure → wait_recovery → start
```

### Check all stuck postgres strands

```ruby
bundle exec ruby -e "
require_relative 'loader'
PostgresServer.all.each do |s|
  st = s.strand&.reload
  puts \"server=#{s.id[0..7]} resource=#{s.resource&.name || 'orphaned'} label=#{st&.label} try=#{st&.try}\"
end
"
```

### Check a specific resource

```ruby
bundle exec ruby -e "
require_relative 'loader'
r = PostgresResource.first(name: '<name>')
s = r.servers[0]
st = s.strand.reload
puts \"state=#{r.display_state} label=#{st.label} try=#{st.try} schedule=#{st.schedule} lease=#{st.lease}\"
"
```

## Diagnosing by Label

### `bootstrap_rhizome`

Rsync's the local `rhizome/` directory to the VM. If stuck here:
- VM may not be reachable via SSH yet (check VM is in `running` state)
- Network/firewall issue between control plane and VM

### `initialize_empty_database`

Runs `postgres/bin/initialize-empty-database` on the VM via daemonizer2.

**Check daemonizer status on the VM:**
```bash
ssh -i /tmp/pg_ssh_key_<name> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubi@<ip> \
  "sudo systemctl list-units 'daemonizer2*' --all --no-pager"
```

**Check daemonizer journal:**
```bash
ssh -i /tmp/pg_ssh_key_<name> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubi@<ip> \
  "sudo journalctl -u daemonizer2-initialize-empty-database.service --no-pager -n 50"
```

**Rhizome is rsync'd live** — edits to `rhizome/` are picked up on the next provision without rebuilding the AMI.

## SSH into a Postgres VM

```ruby
# Get VM IP and write SSH key
bundle exec ruby -e "
require_relative 'loader'
r = PostgresResource.first(name: '<name>')
s = r.servers[0]
key = s.vm.sshable.keys.first
File.write('/tmp/pg_ssh_key_<name>', key.private_key)
File.chmod(0600, '/tmp/pg_ssh_key_<name>')
puts s.vm.ip4_string
"
```

Then SSH:
```bash
ssh -i /tmp/pg_ssh_key_<name> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubi@<ip>
```

## Orphaned Records

Orphaned `PostgresServer` records (resource deleted but server not cleaned up) will crash `monitor.1` with `NoMethodError: undefined method 'tags' for nil` in `metrics_config`.

**Detect:**
```ruby
bundle exec ruby -e "
require_relative 'loader'
orphans = PostgresServer.all.select { |s| s.resource.nil? }
puts \"Found #{orphans.count} orphaned servers\"
orphans.each { |s| puts s.id }
"
```

**Clean up:**
```ruby
bundle exec ruby -e "
require_relative 'loader'
PostgresServer.all.select { |s| s.resource.nil? }.each do |s|
  puts \"Destroying orphaned server #{s.id}\"
  s.destroy
end
"
```

## Zombie Strands

Strands with no corresponding model record keep crash-looping and waste resources. High `try` counts (hundreds+) with no `PostgresServer` row is a clear signal.

**Detect:**
```ruby
bundle exec ruby -e "
require_relative 'loader'
server_strand_ids = PostgresServer.all.map { |s| s.strand&.id }.compact
zombie_strands = Strand.where(prog: 'Postgres::PostgresServerNexus').exclude(id: server_strand_ids).all
zombie_strands.each { |s| puts \"zombie strand=#{s.id} label=#{s.label} try=#{s.try}\" }
"
```

**Clean up (delete semaphores first):**
```ruby
bundle exec ruby -e "
require_relative 'loader'
zombie_id = '<strand-uuid>'
DB[:semaphore].where(strand_id: zombie_id).delete
DB[:strand].where(id: zombie_id).delete
puts 'done'
"
```

## Devcontainer: Foreman

When running in the devcontainer, foreman manages:
- `respirate.1` — strand runner (polls DB every 5s)
- `monitor.1` — resource monitor

Logs: `/var/log/foreman/foreman.log`

If foreman crashes with exit code 2, `monitor.1` hit an unhandled exception — check for orphaned records (see above), fix them, then restart foreman.
