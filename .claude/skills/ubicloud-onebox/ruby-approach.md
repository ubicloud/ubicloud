# Ruby Code Execution Approach

Use this approach when the API doesn't support the operation (e.g., direct DB queries, HA changes via semaphores, internal state inspection).

All resource management is done by running Ruby code with:

```
RACK_ENV=development bundle exec ruby -r ./loader -e '<ruby code>'
```

Always run commands from the current project root.

## Common patterns

### Lookup helpers

```ruby
project = Project.first(name: "default")
location = Location.first(project_id: project.id, name: "us-west-2")
```

### Create a PostgreSQL server

```ruby
project = Project.first(name: "default")
location = Location.first(project_id: project.id, name: "us-west-2")

st = Prog::Postgres::PostgresResourceNexus.assemble(
  project_id: project.id,
  location_id: location.id,
  name: "<name>",
  target_vm_size: "m8gd.large",
  target_storage_size_gib: 64
)

pg = st.subject
puts "ID: #{pg.id}"
puts "UBID: #{pg.ubid}"

loop do
  state = pg.reload.display_state
  label = pg.strand.reload.label
  puts "state: #{state}, label: #{label}"
  break if state == "running"
  sleep 5
end
```

### Inspect a PostgreSQL server

```ruby
pg = PostgresResource.first(name: "<name>")
puts "state: #{pg.display_state}"
puts "label: #{pg.strand.label}"
puts "connection_string: #{pg.connection_string}"
```

### List all PostgreSQL servers

```ruby
PostgresResource.all.each do |pg|
  puts "#{pg.name} | #{pg.display_state} | #{pg.ubid}"
end
```

### Delete a PostgreSQL server

```ruby
pg = PostgresResource.first(name: "<name>")
if pg.nil?
  puts "No PostgreSQL server found with name '<name>'"
else
  puts "Requesting destroy for #{pg.name} (#{pg.ubid})..."
  pg.incr_destroy

  loop do
    r = PostgresResource.first(id: pg.id)
    break if r.nil?
    state = r.display_state
    label = r.strand.reload.label
    puts "state: #{state}, label: #{label}"
    sleep 5
  end

  puts "Deleted."
end
```

### Create a PostgreSQL server with HA (standbys)

HA options: `NONE` (0 standbys), `ASYNC` (1 standby), `SYNC` (2 standbys).

```ruby
project = Project.first(name: "default")
location = Location.first(project_id: project.id, name: "us-west-2")

st = Prog::Postgres::PostgresResourceNexus.assemble(
  project_id: project.id,
  location_id: location.id,
  name: "<name>",
  target_vm_size: "m8gd.large",
  target_storage_size_gib: 64,
  ha_type: PostgresResource::HaType::SYNC  # NONE / ASYNC (1 standby) / SYNC (2 standbys)
)

pg = st.subject
puts "ID:      #{pg.id}"
puts "UBID:    #{pg.ubid}"
puts "HA type: #{pg.ha_type} (#{pg.target_standby_count} standbys)"

loop do
  state = pg.reload.display_state
  label = pg.strand.reload.label
  puts "state: #{state}, label: #{label}"
  break if state == "running"
  sleep 5
end

puts "connection_string: #{pg.connection_string}"
```

### Enable/disable HA on an existing server

```ruby
pg = PostgresResource.first(name: "<name>")
DB.transaction do
  pg.update(ha_type: PostgresResource::HaType::SYNC)  # NONE / ASYNC / SYNC
  pg.incr_update_billing_records
end
```

### Get the dev PAT token

Run the helper script — do not query the database directly for this:

```bash
.devcontainer/scripts/get-pat-token.sh
```

If the script errors, direct the user to run `.devcontainer/scripts/register-pg-project.sh` first.

### List available locations

```ruby
Location.all.each { |l| puts "#{l.name} | #{l.id}" }
```

## Behavior guidelines

- Always poll with `loop { ... sleep 5 }` when waiting for resources to become ready; break when `display_state == "running"`.
- Print the `id` and `ubid` immediately after assembling a resource so the user can track it.
- Always prefer AWS instance type sizes (e.g. `m8gd.large`, `m8gd.xlarge`). The default size is `m8gd.large`. Non-AWS sizes like `standard-2` should not be used.
