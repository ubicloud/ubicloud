# Terraform generator: open items

A prototype-stage register of things known, deliberately deferred,
and written down so the follow-up author - human or LLM session,
with no access to the development history - starts with a map and a
method instead of archaeology. The first half itemizes the open
items; the second states the working doctrine this codebase was
built under. Each entry says what the generator does today, what
is missing or odd, why it was left that way, and what resolving it
looks like. Everything here is expected to be resolved - or this
file dropped - before a production cut. Architecture and the
derivation rules live in doc/terraform-generator.md.

## 1. Plan-modifier derivation is opt-in, and four resources never opt in

What derivation does: a definition may call
`derive_plan_modifiers!`, and the generator then derives two things
from the spec. Stable computed fields get UseStateForUnknown, so
plans stop churning "(known after apply)" on values that never
change. RequiresReplace is computed as the create plane minus every
update verb's attributes - immutability is exactly what no update
operation can reach.

Today only postgres and vm call it. firewall, project,
private_subnet, and firewall_rule publish no plan modifiers at all:
their plans re-unknown stable computeds on every change, and editing
an immutable attribute plans as an in-place update the API will then
reject, instead of the replacement terraform users expect.

Why it is like this: turning derivation on for the other four moves
their schema goldens, and golden moves are explicit reviewed acts in
this codebase. The opt-in also mirrored the hand-written provider at
parity time.

Follow-up: make derivation the default (keep an escape hatch),
regenerate, record the four golden diffs with intent, and review
them - the RequiresReplace sets especially, since a wrong derivation
there causes destructive plans.

## 2. postgres tags: published, read, accepted - and never sent

The schema publishes `tags` (a list of key/value objects,
computed_optional), reads them from the API, and marks them
`updatable` so a tag edit does not force replacement. But no
operation carries them to the server: the create body omits them by
curation, and the one PATCH route that accepts them is deliberately
not routed (the curation notes sit in
lib/terraform_generator/resources/postgres.rb).

Concretely: a user who sets or edits tags gets a clean plan and an
apply whose update dispatch sends nothing for tags; the post-update
re-read then restores the server's values. The attribute is
effectively read-only while looking writable.

Why it is like this: parity - the hand-written provider had the same
gap - and routing tags is a behavior change that deserves its own
reviewed change, not a side effect of the generator rewrite.

Follow-up, either side works: generator-side, add tags to the patch
verb's attrs (one definition line) and re-record the PATCH body's
wire golden; or API-side (the cleaner end state), fold tags and the
maintenance-window route into PATCH so the PATCH body is the
complete mutability declaration, after which the curation deltas
here delete.

## 3. The timeouts block attaches to postgres only

The generator emits a real, populated timeouts block (schema version
1, with a state upgrader for relics of the earlier bare wire type),
and the create and delete waits consume configured values with env
tuning as the default. But the block attaches only where the
published schema already carried one - postgres, the one resource
with declared async waits. The other five resources accept no
timeouts block; their lifecycle calls are synchronous today, so the
gap is uniformity rather than lost function.

Why it is like this: attaching the block anywhere new is a schema
change per resource, each a golden move awaiting review. The
machinery - Version, upgrader, consumption - is already generic and
attaches automatically wherever a definition's published schema
grows the block.

Follow-up: decide the extent (every resource for uniformity, or
waits-bearing resources only), grow the blocks in the schema goldens
with intent, and regenerate; no new code should be needed.

## 4. Terraform 1.15.8 records schema_version 0 while the provider serves 1

Observed and pinned: fresh applies write instance
`"schema_version": 0` into state even though the provider advertises
version 1 on the wire (`terraform providers schema -json` shows 1,
and version negotiation uses it - the UpgradeResourceState RPC fires
for 0-stamped state). Two consequences. Every subsequent plan
re-upgrades forever, which the engine's identity upgrader makes
free. And `terraform show -json` never invokes upgrade, so a
genuinely old on-disk state in the bare-timeouts shape fails `show`
until a plan or refresh-only apply persists the upgraded form.

Where it is pinned: the postgres upgrade spec asserts the recorded 0
alongside this rationale, so a CLI release that fixes the recording
flips the expectation visibly.

Follow-up: nothing required here. Optionally report upstream with
the minimal repro (serve any framework schema with Version: 1 under
dev_overrides, apply, read the state file); when the recording is
fixed, update the spec expectation and delete this entry.

## Working doctrine for whoever iterates next

Written for a session with no history here. These rules are the
distilled cost of the mistakes already made; each one was paid for.

**The golden families are the contract.** Two golden sets pin the
user-visible surface: the schema goldens (the published terraform
schema for every resource and datasource) and the wire goldens (the
terraform state types and API body shapes, checked by
TestWireGoldens in the provider repo). Any diff in either is a
user-visible change. `rake terraform:check` makes drift loud;
recording is deliberate - `rake terraform:goldens` for schemas,
`UPDATE_WIRE_GOLDENS=1 go test ./internal/provider/ -run
TestWireGoldens` for wire - and every recording deserves a commit
message stating what moved and why. `rake terraform:true_up` is the
one-command ritual when you intend to absorb changes: regenerate,
true both families, rebuild docs, verify. Never run it before you
know what you expect it to change.

**Byte-identity is the refactor proof.** A pure refactor of the
generator must regenerate byte-identical provider output - an empty
diff in the provider checkout is the mechanical proof. If the diff
is not empty, the change was not pure: either fix it, or promote it
honestly to a deliberate change with recorded golden intent.

**The battery, in order, and its two traps.** Regenerate every
resource; build the provider; rebuild the provider binary the spec
suite runs against before trusting the suite - a stale binary
produces false greens, and this bit the project three times; vet;
run the provider's go tests; `rake terraform:check`; then the full
spec suite (spec/terraform/run). Second trap: multi-edit scripts
that assert-and-abort can die before writing anything, after which
every gate passes vacuously. Confirm the edit actually landed - the
diff exists - before reading any green as meaningful. Upstream CI
gates count too: rubocop over the generator, harness, and Rakefile
(`bundle exec rubocop lib/terraform_generator spec/terraform
Rakefile`), and the harness files must stay outside the main suite's
`*_spec.rb` pattern. The Terraform provider generation workflow runs
the full loop; keep it green.

**Changes have homes.** Behavior shared across resources belongs in
the engine (support/gen_support.go, embedded at generation time);
the module's non-derived files - go.mod, main, provider wiring,
support packages, tests, examples - live verbatim in support/tree
and are emitted with everything else, so the provider repo is a
publishing target, never an input;
per-resource rendering shape belongs in the templates; per-resource
facts belong in the definitions, declaratively. Protocol-specific
logic stays inside its one update arm until a second declarer
exists - the config-merge and exclusive arm templates say so in
their own comments. Do not generalize speculatively.

**Identity doctrine.** Name is the deliberate uniform idempotency
key: user-chosen, known before the create commits. The server id
exists only after. Ambiguous create outcomes (transport error,
bodyless 200) reconcile by probing for the name; clean rejections
never reconcile; import is the explicit adoption path; the rename
choreography is the honest consequence of name-as-key, not a bug.
The engine header in gen_support.go states this - read it before
touching create or update.

**Specs pin the wire and the artifact.** The harness proves
behavior at the HTTP boundary (the request gate); meta-specs read
the emitted source itself (the verb-order spec scans the generated
verb table, because the table's order is the dispatch order). When
a refactor changes the artifact a meta-spec reads, upgrade the spec
with the artifact. Curation deltas in definitions (`omit`, unrouted
attributes) must carry a comment saying why; an uncommented
curation is a bug.

**Docs track reality.** doc/terraform-generator.md's divergences
section is a claims list; if a change makes a sentence there false,
the same change fixes the sentence. The commit messages in this
series were held to the same bar - keep it that way.
