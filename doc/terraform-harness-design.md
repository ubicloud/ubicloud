# Terraform harness: design

This document designs the harness that tests the terraform provider against clover's API. The
generator and the provider are designed in `doc/terraform-generator-design.md`, and the decisions
behind the harness are in `doc/terraform-generator-brief.md`, chiefly "The harness settles objects
with hooks, and runs no progs" and "Deleting code is a high priority".

Sections 0 to 4 are the guide for an engineer who writes examples. Sections 5 to 10 record the
design: the examples each type brings, the costs, what the harness leaves out and why, the open
questions, the evidence and the risks.

## 0. In short

The harness runs real terraform and the real provider binary against clover's API in process, so
that "terraform does X wrong" can be written as an rspec example. It lives in `spec/terraform/`, the
one part of the terraform work tied to clover's test infrastructure.

- **The example.** An engineer passes HCL to `tf.apply` and asserts on the plan, the requests the
  provider sent, the database or the state, with RSpec's matchers on plain values. A typical
  misbehaviour takes five to ten lines.
- **The API runs on the example's thread.** Puma's threads only carry bytes. The example's thread
  runs each request through `RACK_TEST_APP`, the app the route specs call, inside the example's
  rollback transaction, so committee, the token check, authorization and duplicate-query detection
  apply, mocks reach the API, and the rollback is the cleanup.
- **Hooks, not progs.** After the API accepts a change, `settle_<table>` puts the object in the
  resting state the API reports for it. A type that the API reports at rest from the start needs no
  hook.
- **Gates.** `at(:response, "POST postgres/db") { it.answer(502) }` runs once, on the example's
  thread, while the provider waits for the answer. A gate that never runs fails the example.
- **The ledger.** Every request is recorded with its path shown relative to the project, each id
  shown as `@` and the object's name, so `expect(tf.apply(hcl).mutations).to eq ["POST
  postgres/@db/upgrade", "PATCH postgres/@db"]` asserts the order of the verbs and that the provider
  addressed the database by id.
- **Nothing hangs.** Every terraform command has a 30-second deadline, after which terraform is
  killed and the failure names the last request.

## 1. The API

Every file in `spec/terraform/` whose name ends in `_harness.rb` requires `spec_helper` beside it,
and its examples get these methods:

```ruby
tf                                    # the example's terraform directory, made on first use
tf.apply(hcl = nil, *flags)           # => Ledger of the requests the command sent
tf.plan(hcl = nil, *flags)            # => Plan
tf.destroy(*flags)                    # => Ledger
tf.run(command, *args)                # => Ledger; any other command, as tf.run("state", "rm", "ubicloud_vm.web")
tf.state(address = nil)               # one resource's attributes, or every resource's by address

ledger                                # => Ledger of every request in the example
ledger.requests(pattern = "*")        # => ["POST postgres/db", "GET postgres/@db", ...]
ledger.mutations(pattern = "*")       # the same without the GETs
ledger.entries                        # => [Request], whose body and response are the raw request and the parsed answer

plan.actions                          # => {"ubicloud_vm.web" => :update}; also :create, :replace, :delete, :read
plan.empty?                           # nothing to create, update, replace or delete
plan.output                           # terraform's text, the diff included

at(:request, pattern) { |request| }   # once, before the API serves the first matching request
at(:response, pattern) { |request| }  # once, after the API has answered it, before the answer leaves
request.answer(status, body = nil, headers = {})  # send this instead; at :request the API never runs

project                               # an account, and a project with a token in its Admin tag, made on first use
settle(object)                        # puts the object at rest, as after a change the API accepts
```

A command given HCL writes it to `main.tf` first. The state lives in the directory and carries from
command to command, so `tf.apply(database(size: "standard-4"))` updates what the previous command
created. Flags go to terraform as given, such as `"-target=ubicloud_vm.web"` or `"-var=region=eu"`.
Commands run at terraform's default parallelism of 10, as customers run them.

A command whose terraform fails raises `TerraformHarness::Error` with terraform's errors. An example
that expects the failure says so with RSpec, and goes on after it:

```ruby
expect { tf.apply(hcl) }.to raise_error(TerraformHarness::Error, /already taken/)
```

An exception inside the API is raised again in the example once terraform has exited, whatever
terraform did, because a request that makes the API raise is a fault in the provider or in the API;
an expected `TerraformHarness::Error` cannot swallow it. Committee raises its errors in tests, so a
request the spec forbids is reported this way.

`Plan#inspect` is terraform's diff, so a failed `expect(tf.plan).to be_empty` shows what changed. An
assertion on one attribute matches the text: `expect(plan.output).to match(/public_key .* # forces
replacement/)`. `tf.state` reads `terraform show -json`, so it takes terraform's addresses, with
`data.` prefixes and instance keys: `tf.state('ubicloud_firewall_rule.office["22"]')`.

A path is shown as an example writes it: without `/project/<the example's project>`, without
`location/eu-central-h1/`, the location every example uses, and with the id of each object that has
a name shown as `@` and that name, as it was when the request arrived. So a rename shows as `POST
firewall/@web/rename` and a read by name as `GET firewall/web`, and the difference tells whether the
provider addressed the object by id. A pattern is a glob over the verb and the shown path, in which
`*` matches any characters, `/` included: `"POST postgres/db"`, `"* postgres/*"`.

The ledger a command returns covers that command, and `ledger` the whole example. Each resource's
requests repeat exactly from run to run, but the order among independent resources follows
terraform's walk and varies. An example with several resources in flight therefore filters by
resource, as in `mutations("* postgres/*")`, or orders them with `depends_on`.

A gate injects a fault the provider must survive: a 429 or a "busy" refusal before the API runs, or
a 502 after it has. Its block runs on the example's thread while the provider waits for the answer,
so it can also read the database and use `expect`, and no other request reaches the API meanwhile. A
failing expectation in a block stops terraform at once. `at` registers the block as an RSpec message
expectation, so a gate that never ran fails the example at RSpec's mock verification, which names
the block's file and line, and a mistyped pattern cannot pass silently.

`settle` is for a change an example makes outside the API, as the control plane would make it.
Without it the provider reads rows the control plane has not finished with.

`bundle exec rspec spec/terraform/postgres_harness.rb:42` runs one example with nothing set in the
environment. Terraform's variables, such as `TF_LOG_PROVIDER`, pass through to it.

## 2. An example

```ruby
# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ubicloud_firewall" do
  def firewall(name) = <<~HCL
    resource "ubicloud_firewall" "web" {
      location = "eu-central-h1"
      name     = "#{name}"
    }
  HCL

  it "renames a firewall in place" do
    tf.apply firewall("web")
    fw = Firewall.first(project_id: project.id)

    expect(tf.plan(firewall("web-2")).actions).to eq("ubicloud_firewall.web" => :update)
    expect(tf.apply.mutations).to eq ["POST firewall/@web/rename"]
    expect(fw.reload.name).to eq "web-2"
    expect(tf.state("ubicloud_firewall.web")["id"]).to eq fw.ubid
    expect(tf.plan).to be_empty
  end
end
```

`tf.apply(hcl)` writes the HCL to `main.tf`, beside an override file holding the provider block, and
runs `terraform apply`; while terraform runs, the example's thread serves each request the provider
sends. The firewall that `Firewall.first` finds is the row the API created in the example's
transaction, and the rollback at the end of the example removes it. `tf.apply` with no argument
applies the configuration that `tf.plan` wrote.

More shapes are in §5: the order of verbs, adoption after a 502 and drift from an auto-scale in
`postgres_harness.rb`; a lost answer to a type without a name, and a race on a name, in
`network_harness.rb`; an import of a write-only input, and a create that outlives its timeout, in
`vm_harness.rb`; a refusal retried after `Retry-After`; and an exception inside the API, in
`ssh_public_key_harness.rb`.

## 3. How it works

### 3.1 The API runs on the example's thread

```
terraform ─gRPC─ provider ─HTTP─▶ Puma thread                   example thread, inside tf.apply
                                   │ puts the request on the     │ pops the next event:
                                   │ queue and waits ───────────▶│  a request: ledger, request gate,
                                   │                             │    RACK_TEST_APP, hook, response gate
                                   │ ◀──────────── answer ────── │  terraform's exit: returns
                                   ▼ writes it                   ▼  the deadline: kills terraform, raises
```

Puma runs in the process, on 127.0.0.1 and a port the kernel chooses, with 16 threads; terraform
runs at most ten operations at once, and the engine sends one request at a time for each. Puma's
Rack app puts each request on one queue and waits for the answer. The provider dials 127.0.0.1,
because Go does not resolve `api.localhost` here, and the harness sets `Host: api.ubicloud.com`,
which clover's host routing needs.

While terraform runs, the example's thread is inside the command. It pops one event at a time: a
request; terraform's exit, which a thread waiting on the process pushes; or the deadline, which is
the pop's timeout. Nothing polls and nothing sleeps. Serving a request records it in the ledger,
runs the matching request gate, calls `RACK_TEST_APP` and reads the whole body, runs the hook if the
API accepted a change, runs the matching response gate, and hands the answer back. An exception
inside the app is recorded on the request and answered with an empty 500, and the command raises it
once terraform has exited.

After every command the harness kills terraform's process group, so no provider outlives the command
to send a request later, and each command first answers 503 to anything left on the queue. A request
that still arrived late from an earlier example would carry a token that the rollback removed.

This is how the route specs run the app: rack-test calls it on the spec's thread, inside the spec's
transaction. So a mock set in the example reaches the API; committee checks the provider's requests
and the API's answers; duplicate-query detection fails an N+1 query that only the provider triggers;
and the authorization and audit-log checks, which clover makes after each request in unfrozen tests,
cover every route the provider takes. Requests run one at a time, in arrival order. The harness sets
`Thread.current[:route_spec]` for the whole example, as the route specs do, so a request that
reaches for SSH raises.

### 3.2 The database

Each example runs inside the main spec helper's `DB.transaction(rollback: :always, auto_savepoint:
true)`, unchanged. Every request runs on the example's thread and so in that transaction, and the
API's `DB.transaction` blocks become savepoints, as in a route spec. Four things follow.

- **The rollback is the cleanup.** Nothing is destroyed at the end of an example, and a killed run
  leaves only an aborted transaction.
- **SQL's clock stands still.** `now()` is the transaction's start for the whole example, so every
  row the example makes has the same `created_at`, and a list ordered by `created_at` alone comes
  back in an arbitrary order. Ruby's `Time.now` still advances. A state derived from elapsed time
  is reached by moving a timestamp back, never by waiting.
- **`after_commit` hooks never fire**, as in the route specs.
- **A run must have its database to itself.** The main spec helper drops the `deleted_record`
  partitions at the end of each run, so a run that shares its database with one that finishes first
  fails its next destroy. Each run takes a `TEST_ENV_NUMBER` that no other run uses, as every rspec
  run in clover must.

### 3.3 The hooks

No prog runs in the harness. `spec/terraform/settle.rb` does what the control plane would have done
by the time an object is at rest, in one method per table, and is the only file of the harness that
names a type.

After the API answers anything but a GET with 2xx, the harness calls `settle_<table>`, if
`settle.rb` defines it, with the object the change was made to: the one whose id the answer carries
or, for a verb or a DELETE whose answer carries none, the last id in the path, resolved when the
request arrived. It skips an object whose row is gone, as after a synchronous delete. The hook
decides what at rest means; for an object being deleted, the hook destroys it. The postgres hook
begins:

```ruby
def settle_postgres_resource(pg)
  return pg.destroy if pg.destroy_set?

  pg.strand.update(label: "wait")
  Semaphore.where(strand_id: pg.id, name: "initial_provisioning").destroy
  # and puts each server at the target version, size and storage
```

The hook runs before the response gate and before the answer leaves, so the provider's first read
after a create sees the object running and its first read after a delete gets 404. An answer a gate
replaces after the API ran does not stop the hook: an object the engine adopts by name is at rest
like any other.

At rest means that nothing is left for the control plane to do, deferred work included: the postgres
hook puts the servers at their targets, as the recycle after a resize does in the maintenance
window. The time before the recycle, in which the API refuses an upgrade, is a convergence
phenomenon, which the harness does not test. An example that needs an object left pending stubs its
hook.

A hook can drift from the prog it stands for, and two checks bound the drift that terraform could
see. Committee validates each answer's `state` against its enum, so a hook that leaves a value the
spec does not list makes the request raise. A hook that leaves an object pending makes the provider
wait until the deadline, whose failure names the request and its state.

### 3.4 Building the provider and running terraform

The first harness file to load builds the provider, once per process:

1. `rake terraform:generate`, in a separate process, writes the generated files into
   `terraform/provider/`, keeping any file the engineer has edited and printing its name.
2. `go build -o tmp/terraform/bin/terraform-provider-ubicloud .` runs in `terraform/provider`, with
   `GOTOOLCHAIN=local` and `-cover`. It runs every time the harness loads, so the harness never
   tests a stale binary; with nothing changed it takes about 0.2 s.
3. `tmp/terraform/dev.tfrc` maps `registry.terraform.io/ubicloud/ubicloud` to that directory with
   `dev_overrides`, so that no command needs `terraform init`.

Each example's directory is `tmp/terraform/runs/<example id>/`. It is emptied when the example
starts and left afterwards, so that any example's run, passed or failed, can be read until the
example runs again. It holds `main.tf`, the example's HCL unchanged; the state; one log per command,
such as `02-plan.log`; and `harness_override.tf`, which terraform merges over `main.tf`:

```hcl
terraform {
  required_providers {
    ubicloud = { source = "ubicloud/ubicloud" }
  }
}

provider "ubicloud" {
  api_endpoint  = "http://127.0.0.1:41733"
  api_token     = "pat-..."
  project_id    = "pj..."
  poll_interval = "10ms"
}
```

Terraform accepts both blocks whether or not `main.tf` has them, and a pasted provider block takes
the override's settings. Pasted HCL needs nothing more, except that a backend, a module or another
provider would need `terraform init` and the registry, so an engineer reducing a report removes
them.

Each command runs `terraform <command>` in the directory, in a new process group, with its output in
its log file, so that no pipe can fill and stall terraform. In terraform's environment the harness
sets `TF_CLI_CONFIG_FILE`, `TF_IN_AUTOMATION`, `CHECKPOINT_DISABLE`, `TF_INPUT=0`,
`TF_CLI_ARGS=-no-color` and `-auto-approve` for apply and destroy, and removes `UBICLOUD_API_TOKEN`,
`UBICLOUD_API_ENDPOINT` and `UBICLOUD_PROJECT_ID`, so that an engineer's token cannot reach a
provider block that the override does not cover. A plan runs with `-out=tfplan -detailed-exitcode`,
and only a plan whose exit status says it changes something runs `terraform show -json tfplan` for
its actions. Every command also gets `GOCOVERDIR=tmp/terraform/cover/harness`, and each provider
process writes its counters there when terraform stops it.

### 3.5 The ledger

Each request is added to the ledger as it arrives. The shown path is computed before the API runs,
with one `UBID.decode` per id in the path, outside duplicate-query detection. Each request keeps its
body as sent and its answer parsed, which `ledger.entries` gives to an example or a debugger.

### 3.6 The deadline

Each terraform command has a deadline of 30 seconds, which a passing example never comes near. At
the deadline the harness kills terraform's process group and raises, naming the last request and its
answer, which for a provider waiting on an object nothing will change reads like `apply#1 GET
vm/@web 200 state=creating`.

The engine's timeouts cannot serve instead: they are per resource, from each resource's
`timeouts` block, with defaults of an hour or two. An example about the engine's deadline sets the
`timeouts` block in its HCL, and the engine's error names the last state it saw.

A request that blocks inside the app blocks the loop, and the deadline cannot fire until it returns.
Only a loop inside the app could do this, and it would hang a route spec too; the workflow's timeout
ends it.

### 3.7 What tests the harness

The examples that use the harness test it. `spec/terraform/examples_harness.rb` applies each
generated resource example as the documentation shows it, checks that a plan then shows no change,
and destroys it. That covers every type's create, read and delete against the API without a line
written for the type, and is where a missing hook first shows. Every example that expects a failure
fails if the harness stops raising terraform's errors. The one fault that could pass silently, an
exception inside the API, is tested by an example in `ssh_public_key_harness.rb`, which stubs a
serializer to raise and expects that exception.

## 4. What a failure prints

RSpec prints its failure first. The harness removes its frames from the backtrace, so that
`Failure/Error:` names the example's line rather than the harness's. Below the failure, through the
example's `extra_failure_lines` metadata, it adds the last 40 requests the API received in the
example and the directory where the run is kept. Each request takes one line: the command, the verb
and the shown path, the status or the exception's class, the `state` an answer carries, and the
error message of a 4xx or 5xx answer.

```
  1) ubicloud_postgres plans no change after a storage auto-scale
     Failure/Error: expect(tf.plan).to be_empty
       expected `#<Plan   # ubicloud_postgres.db will be updated in-place
         ~ resource "ubicloud_postgres" "db" {
             id           = "pg..."
           ~ storage_size = 256 -> 128
         }
       >.empty?` to be truthy, got false
     # The last of the 3 requests the API received in this example:
         apply#1 POST postgres/db 200 state=creating
         apply#1 GET postgres/@db 200 state=running
         plan#2 GET postgres/@db 200 state=running
     # Kept for inspection: tmp/terraform/runs/postgres_harness-1-4/
```

An exception inside the API is printed as RSpec prints any exception: its class, its message, and a
backtrace that runs from clover's frames to the example's line. Its request shows in the lines below
with a 500 and the exception's class, such as `500 Committee::InvalidResponse`.

The kept directory holds the configuration, each command's log and the state. Neither it nor the
lines above hold request bodies or whole answers; `ledger.entries.map { [it.to_s, it.body,
it.response] }` gives them, from the example or from a debugger. The provider's debug log slows a
run by 15 to 35 %, so it is off; `TF_LOG_PROVIDER=DEBUG TF_LOG_PATH=provider.log` writes it into
each example's directory, with each request's method, path and status.

## 5. The examples each type brings

The commit that adds a type adds a hook to `spec/terraform/settle.rb` if the API reports a new
object of the type as pending, an example for each update verb, an import for a named type, and
whatever behaviour examples the type needs. Each file starts with `# frozen_string_literal: true`
and `require_relative "spec_helper"`, which the examples below leave out.

§2's example goes into `network_harness.rb`. Against the prototype's provider it failed at the
second apply with "Update of firewall is not supported", and the ledger showed that no rename was
sent.

### 5.1 Postgres: an upgrade and a resize in one apply reach the API in that order

```ruby
RSpec.describe "ubicloud_postgres" do
  def database(version: "17", size: "standard-2") = <<~HCL
    resource "ubicloud_postgres" "db" {
      location       = "eu-central-h1"
      name           = "db"
      size           = "#{size}"
      storage_size   = 128
      target_version = "#{version}"
    }
  HCL

  it "upgrades before it resizes when one apply changes both" do
    tf.apply database

    expect(tf.apply(database(version: "18", size: "standard-4")).mutations).to eq ["POST postgres/@db/upgrade", "PATCH postgres/@db"]
    pg = PostgresResource.first(project_id: project.id)
    expect([pg.target_version, pg.target_vm_size]).to eq ["18", "standard-4"]
    expect(tf.plan).to be_empty
  end
end
```

The order comes from the definition, `postgres: {order: %i[upgrade]}`. In production the API
enforces it too, for a while: a resize leaves the database needing convergence until its recycle in
the maintenance window, and the upgrade route refuses a database that needs convergence. The
harness does not reproduce that window, since the postgres hook puts the servers at their targets
after each verb. In the harness, then, the API accepts the two verbs in either order, and only the
ledger checks the order.

### 5.2 A create whose answer is lost adopts the named object, or reports

```ruby
  it "adopts the database when a proxy answers 502 after the API created it" do
    at(:response, "POST postgres/db") { it.answer(502) }
    tf.apply database

    pg = PostgresResource.first(project_id: project.id)
    expect(PostgresResource.where(project_id: project.id).count).to eq 1
    expect(ledger.mutations).to eq ["POST postgres/db"]
    expect(ledger.requests).to include "GET postgres/db"
    expect(tf.state("ubicloud_postgres.db")["id"]).to eq pg.ubid
    expect(tf.plan).to be_empty
  end
```

The API creates the database, the hook puts it at rest, and the gate replaces the answer with a 502,
as a proxy would. The engine cannot tell whether the create happened, so it reads the database by
name, which shows as `GET postgres/db` rather than `GET postgres/@db`, and adopts it, sending no
second POST. A closed connection takes the same path in the engine as a 502, and the engine's `go
test` covers its classification of transport errors. Against the prototype, the 502 made the
provider report a failure and leave the row orphaned; this example exists to catch that defect.

A type without a name reports instead, in `network_harness.rb`:

```ruby
  it "reports a firewall rule whose create answer was lost, with the import to run" do
    tf.apply firewall("web")
    at(:response, "POST firewall/@web/firewall-rule") { it.answer(502) }
    rule = <<~HCL
      resource "ubicloud_firewall_rule" "ssh" {
        location    = "eu-central-h1"
        firewall_id = ubicloud_firewall.web.id
        cidr        = "10.0.0.0/8"
      }
    HCL
    expect { tf.apply(firewall("web") + rule) }.to raise_error(TerraformHarness::Error, /with ubicloud_firewall_rule\.ssh,.*terraform import ADDRESS/m)
    expect(FirewallRule.where(firewall_id: Firewall.first(project_id: project.id).id).count).to eq 1
  end
```

Terraform does not tell the provider a resource's address, so the engine's hint reads `import it
with: terraform import ADDRESS <location>/<firewall>/ID`, and the address appears only in
terraform's context line above it.

### 5.3 Drift from a storage auto-scale plans no change

```ruby
  it "plans no change after a storage auto-scale" do
    tf.apply database
    pg = PostgresResource.first(project_id: project.id)

    allow(Util).to receive(:send_email)
    allow(pg.representative_server).to receive(:disk_usage_percent).and_return(91)
    pg.handle_storage_auto_scale
    settle(pg)

    expect(pg.target_storage_size_gib).to eq 256
    expect(tf.plan).to be_empty
  end
```

The database's `wait` label calls `handle_storage_auto_scale` to decide on an auto-scale. The
example calls it directly, stubbing the disk probe, which would read the server over SSH, and the
email, as the main suite's specs of the method do. `settle(pg)` then puts the servers at their
targets, so the plan compares the configuration with the database as a customer who reports "it
auto-scaled last week" has it. Without `settle`, the example passed against a provider with the
fault; with it, that provider planned `storage_size 128 => 64`.

### 5.4 An imported VM plans no replacement for its write-only public_key

```ruby
RSpec.describe "ubicloud_vm" do
  let(:key) { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOT0eJ0n8m0KpQ alice@example.com" }

  def vm(public_key = key) = <<~HCL
    resource "ubicloud_vm" "web" {
      location   = "eu-central-h1"
      name       = "web"
      public_key = "#{public_key}"
    }
  HCL

  it "imports a VM without replacing it for its write-only public_key" do
    tf.apply vm
    tf.run "state", "rm", "ubicloud_vm.web"

    plan = tf.plan <<~HCL + vm
      import {
        to = ubicloud_vm.web
        id = "eu-central-h1/web"
      }
    HCL
    expect(plan.actions).to eq("ubicloud_vm.web" => :update)
    expect(tf.apply.mutations).to be_empty
    expect(tf.state("ubicloud_vm.web")["public_key"]).to eq key
    expect(tf.plan).to be_empty
  end
end
```

`state rm` leaves a VM that terraform's state does not know, as one made by the old provider or the
CLI is. The API never echoes `public_key`, so after the import its state is null, and the
replace-unless-imported modifier (`doc/terraform-generator-design.md` §7.4) adopts the configured
value in an update that sends nothing. The prototype planned a replacement. The commit that adds
each named type writes an example of this shape for it.

### 5.5 More shapes

A race on a name needs no gate. Requests are served one at a time, and a create sends nothing before
its POST, so a row made before the apply is the same race as one made at a gate:

```ruby
it "fails the create, and keeps no state, when the name is taken first" do
  Firewall.create(name: "web", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
  expect { tf.apply firewall("web") }.to raise_error(TerraformHarness::Error, /already taken/)
  expect(tf.state).to be_empty
end
```

A create that outlives its timeout keeps the object in state, tainted. Stubbing the hook leaves the
VM pending, and the engine's deadline ends the create with an error that names the last state it
saw and the timeout to raise. In `vm_harness.rb` the example first sends a create through the API
and rolls it back, so that the provider's POST does not spend the one second allowed on loading
the code a VM create runs, and it is the wait for the VM to settle that times out:

```ruby
it "keeps the VM in state, tainted, when the create outlives timeouts.create" do
  allow(TerraformHarness::Settle).to receive(:settle_vm)
  slow = <<~HCL
    resource "ubicloud_vm" "web" {
      location   = "eu-central-h1"
      name       = "web"
      public_key = "#{key}"
      timeouts {
        create = "1s"
      }
    }
  HCL
  expect { tf.apply slow }.to raise_error(TerraformHarness::Error, /timeouts\.create/)
  expect(tf.state("ubicloud_vm.web")["id"]).to eq Vm.first(project_id: project.id).ubid
  expect(tf.plan.actions).to eq("ubicloud_vm.web" => :replace)
end
```

A refusal the API never saw, which the provider must retry after the delay it names:

```ruby
at(:request, "POST firewall/web") { it.answer(429, nil, "retry-after" => "1") }
```

An exception inside the API is tested in `ssh_public_key_harness.rb`. The engine does not retry a
500, so the apply ends at once:

```ruby
it "raises an exception from inside the API as itself" do
  allow(Serializers::SshPublicKey).to receive(:serialize_internal).and_raise(RuntimeError, "boom")
  expect { tf.apply key }.to raise_error(RuntimeError, "boom")
end
```

A customer's file can be pasted whole, as `<<~'HCL'` so that Ruby leaves `${...}` to terraform,
once its `backend` block is removed: terraform asks for `terraform init` when a configuration
declares a backend, and the harness never runs it.

## 6. Cost

Measured in a four-CPU container shared with other work, without the provider's debug log:

| Step | Time |
|---|---|
| loading clover lazily | about 1 s, then about 2.5 s in the first request |
| `rake terraform:generate` with no types | about 0.6 s, of which bundler and the Rakefile 0.5 s |
| `go build` with nothing changed | 0.21 to 0.23 s |
| `terraform apply`, a firewall's create | median 0.34 s |
| `terraform plan` with no change | median 0.25 s |
| `terraform plan` and `show -json` | median 0.38 s |
| `terraform destroy`, one firewall | median 0.39 s |
| a database create settled by a hook | median 0.52 s |
| an example's account, project and token | 11.5 ms |
| the provider's debug log, when on | 15 to 35 % more |

A typical example of three or four commands takes about a second. The engineer's loop, `bundle
exec rspec spec/terraform/postgres_harness.rb:42`, takes about six seconds: a second of loading,
2.5 s of lazy loading in the first request, under a second to generate and build, and the example.
For the first cut, the examples harness should take about a second for each of thirteen resource
types, and forty to sixty behaviour examples about 1.2 s each: about a minute and a half in all, in
one process.

The harness comes to about 300 lines in `spec/terraform/spec_helper.rb`, 5 to 20 lines per type in
`settle.rb`, about 15 in `examples_harness.rb`, a 6-line `.rubocop.yml` that turns off
`RSpec/SpecFilePathSuffix` and `RSpec/DescribeClass` for `*_harness.rb`, and about 5 lines in the
`Rakefile`. The prototype's harness was 696 lines.

## 7. What the harness leaves out, and why

| Left out | Why |
|---|---|
| Running progs: a stepper, a virtual clock, a data plane answering SSH, a world of hosts | The harness tests the provider against the states the API reports; hooks put objects at rest. Progs are not tested across labels and convergence, because of the combinatoric explosion under composition |
| A manual mode, a step or age command, a second hook for deferred work | An example that needs an object left pending stubs its hook or edits rows; a hook does the deferred work too; `go test` covers the engine's wait loop |
| A generic baseline over every type: each verb with alternate values, each replaced input, import, adoption, waits, and `ONLY=` | The examples harness, `go test`, and an example per update verb and import in each type's commit (§8, question 2) |
| Fixture types behind a Go build tag | The harness is built with the first generated type |
| Parallel workers, a database per worker, build and database locks | One process; parallel workers would save under a minute |
| A stall detector over pending reads | The deadline names the last request and its state |
| Losing an answer by hijacking Puma's socket | A 502 at `:response` drives the engine into the same unknown outcome; `go test` covers a closed connection |
| A `fails:` option, and a check that every gate fired | `raise_error`; `at` is an RSpec message expectation, which fails a gate that never ran |
| A `destroy_<table>` beside each hook | One `settle_<table>`, called after any accepted change, decides what at rest means |
| Plan helpers that rebuild terraform's diff | `Plan#inspect` and `plan.output` are terraform's text |
| A request log file, token masking, the provider's debug log on by default | The ledger is in memory; the token exists only in a rolled-back transaction; the log costs 15 to 35 % |
| A network fence | Removing the provider's three variables keeps an engineer's token out; without `terraform init` terraform reaches no registry |
| Pasted backends, modules and aliased provider blocks | The engineer removes them when pasting |
| Loading the generator into clover's process | `rake terraform:generate` runs in a separate process |
| A self-test file | The examples that use the harness test it, and §3.7 names the one fault that could pass silently |
| Counting hooks as special cases | Hooks stand for the control plane, not for a derivation rule |

Some mechanism was considered for deletion and kept: the `_harness.rb` suffix, since `*_spec.rb`
would need excludes in `rspec spec`, turbo_tests and the `Rakefile`; generating when the harness
loads, which guards against a stale provider; the deadline; the two gate phases, since a refusal
before the API runs and a lost answer after it ran are different situations; and
`Thread.current[:route_spec]`.

## 8. Open questions

Each has a default that holds until Daniel Farina answers.

1. **Should the harness also run frozen in CI?** The harness runs unfrozen, where clover checks
   after each request that the route authorized and audited, and where duplicate-query detection is
   on. A frozen run would add production's loading and freezing, which the main suite's frozen run
   already covers for the same routes, at about a minute and a half more in CI. The harness stays
   loadable frozen, since it keeps the generator out of clover's process. Default and
   recommendation: unfrozen only; `CLOVER_FREEZE=true` remains possible for a local run.
2. **Should every generated type get verb, import and adoption checks without hand-written
   examples?** A generic baseline came to about 150 lines with a table of alternate values, and it
   rewrote the generated examples to change one value at a time. Without it or hand-written
   examples, an API change that breaks a type's verb would pass the terraform workflow, since `go
   test` covers the engine's generic code but not each type's routes. Default and recommendation:
   no generic checks; each type's commit writes an example of about five lines for each update verb
   and, for a named type, an import.

## 9. Evidence

The design rests on experiments run against clover main with terraform 1.15.8, Go 1.27.3, Ruby
4.0.9, Puma 8.0.2 and Sequel 5.109.0, driving the prototype's provider and an early engine with
three hand-written types.

| Claim | Result |
|---|---|
| The example's thread serves clover's app in the example's transaction, and leaves nothing | a firewall's apply, plan and destroy ran through the app; the next example saw no rows |
| Mocks, committee and duplicate-query detection reach the provider's requests | a serializer stub reached the API, where committee's response check raised; a doubled query raised `DuplicateQueries` |
| Plain `rspec path:line` needs nothing set | 5.0 to 5.7 s for one example |
| Serving on Puma's threads with a shared connection is no better | it needed `SHARED_CONNECTION` set before `db.rb` loads, let other requests run during a gate, and was at most 12 % faster |
| A gate's block sees a quiet API, and a failing expectation stops terraform at once | terraform stopped after 0.24 s |
| A gate that never runs must fail the example | a run that passed one silently hid a defect |
| A lost or 502 answer leads to adoption by name | one POST and one row; the prototype orphaned a row after a 502 |
| Each resource's requests repeat; the order across resources varies | 10 of 10 runs identical per resource; two independent creates came 7 to 3 in one order at parallelism 1, 4 to 6 at 10 |
| Hooks that edit rows settle VMs and databases | a VM create of one POST and one GET; a database `creating`, then `running` after its hook |
| A drift example needs the object at rest after a change made outside the API | without it the example passed against the faulty prototype |
| A DELETE's object must be resolved before the API runs | resolved afterwards, it was nil after a firewall's synchronous delete |
| One override file covers the provider block, with or without one in `main.tf`; a backend needs `init` | the provider dialed the override's endpoint |
| The provider must dial 127.0.0.1 with the API's host set | Go does not resolve `api.localhost` here |
| Every provider process writes coverage counters | 25, 73 and 29 counter files in three runs |
| SQL's clock stands still within an example | `now()` equal at start and end |
| Two runs on one database break at a destroy | the first to finish dropped the `deleted_record` partitions |
| `TF_CLI_ARGS=-no-color` reaches every command | `state list`, `state rm`, `show -json`, `plan` and `apply` printed no color codes |
| An RSpec message expectation can carry a gate's block | with `and_call_original` it ran the block once, and failed an example in which it never ran, naming the block's file and line |

## 10. Risks

1. **No concurrency inside the API.** Requests are served one at a time, so a race between two
   requests in flight cannot be reproduced; the route specs have the same limit.
2. **Hooks can drift** from the progs they stand for, within the bounds that §3.3 describes.
3. **Committee raises in tests**, so an example cannot see the 400 that production gives a request
   the spec forbids; the provider's handling of it is left to `go test`.
4. **No TLS.** The provider speaks plain HTTP to 127.0.0.1.
5. **A missing hook costs the deadline**, 30 seconds for each command that waits, until the type's
   commit adds it.
6. **Lists ordered by `created_at` alone** come back in an arbitrary order while SQL's clock stands
   still, which can differ from production.
7. **A broken deadline shows as a hang** rather than a failure, since no example tests it; the
   workflow's timeout ends the run.
8. **Not yet shown whole.** Most parts ran in the experiments, but the harness has not run as one
   file, and these parts have not run at all: the trimmed backtrace, generation through `rake` when
   the harness loads, the hooks for load balancers and kubernetes, destroying VMs and databases in
   their hooks, the merged coverage report, and the examples harness over a child type whose
   example creates its parent. The commit that builds each part will show that it works.
