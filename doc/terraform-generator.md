# Terraform provider generator

`lib/terraform_generator` is the sole producer of the Go source in
terraform-provider-ubicloud. A resource is described once, in a short
definition file; models, schemas, CRUD, API transport, provider
registration, acceptance-test coverage, and registry docs examples
all derive from the definition plus the live OpenAPI document.

## Layout

    lib/terraform_generator.rb      definition DSL and loader
    lib/terraform_generator/
      reflection.rb                 OpenAPI -> attribute model
      schema.rb                     attribute model -> provider schema
      declarations.rb               Go declarations, transport, examples
      emit.rb, templates/           CRUD rendering and orchestration
      support/gen_support.go        fixed runtime embedded in output
      resources/*.rb                the definitions
    spec/terraform/                 gated acceptance harness

## What derives, and from where

Attribute types, optionality, and descriptions come from the spec.
Sensitivity comes from `format: password`; computed classification
from `readOnly` (resource plane only - datasource keys stay inputs);
write-only handling from `writeOnly`. Update-verb attributes come
from each operation's request body. Plan modifiers are rules, not
lists: `RequiresReplace` is the create plane minus every verb's
attributes; `UseStateForUnknown` attaches to stable computed fields.
Modifier derivation is opt-in per definition
(`derive_plan_modifiers!`); a definition without it publishes a
schema with no modifiers - unifying that is a published-schema change
awaiting its own reviewed golden diff.

A definition therefore contains only what the spec cannot express:
which noun is a managed resource, identity keys, verb choreography
(ordering, exclusivity, tombstone semantics, state-conditioned
guards), async waits, and named curation (e.g. postgres PATCH accepts `tags`, which
terraform does not route; union and bodyless operations declare their
attributes).

## Adding a resource

1. Write `lib/terraform_generator/resources/<name>.rb`. A conforming
   resource is a handful of lines; see `private_subnet.rb`.
2. `rake terraform:true_up` - regenerates sources, records both golden
   families, rebuilds docs, verifies, and prints the provider diff to
   commit. Golden diffs are the review artifact.
3. `spec/terraform/run` - the shared baseline covers the new resource
   automatically (conventional model name, derived fixture and gate
   paths). Add a registry entry only for async convergence hooks or
   curated exceptions; add a bespoke spec only for behavior beyond
   the baseline.

## Verification

    rake terraform:check     freshness, orphans, schema-golden drift
    spec/terraform/run       gated acceptance suite
    rake terraform:true_up   the full ritual after an API change

Generation yields a complete provider module: alongside the derived
files, a verbatim scaffold (`support/tree`: go.mod and go.sum, main,
the provider wiring, the support packages and their tests, the docs
templates and tool shim, the hand-written examples) and copies of the
goldens, which are owned here under `goldens/`. The module lands in a
gitignored `tmp/terraform-provider-ubicloud` by default; publishing
into the provider repo is pointing `UBICLOUD_TF_PROVIDER_REPO` at a
checkout and regenerating. The provider repo is a target, never an
input.

The harness files are `spec/terraform/*_harness.rb`, outside the
default `*_spec.rb` pattern, so the main suite never loads them; the
runner selects them explicitly, builds the module's binary into a tmp
dir (`UBICLOUD_TF_PROVIDER_BIN_DIR`), and runs it against the
in-process server. The `Terraform provider generation` workflow runs
the whole loop in CI, separate from the main Ruby CI and with no
provider checkout - generate, check, build and unit-test the module,
the harness, then the module published as an artifact - triggered by
changes to the generator, the harness, the OpenAPI spec, or the
Rakefile.

Generated files are byte-compared against a fresh render; schema
goldens (`testdata/schema_goldens.json`) hold the reviewed derivation;
wire goldens pin terraform state compatibility, so removing or
renaming a state-visible field is an explicit decision, not an
accident. The harness makes concurrency deterministic with one-shot
request gates that machine-check their own soundness.

## Deliberate divergences

The timeouts block (postgres today; attaching it elsewhere is a
schema change awaiting its own reviewed golden diff) uses the
populated wire type at schema version 1; a state upgrader migrates
states written under the earlier bare-object shape, with the frozen
V0 schema emitted beside it. Empty 200 bodies decode as absent,
matching several endpoints. Both are asserted by goldens.
