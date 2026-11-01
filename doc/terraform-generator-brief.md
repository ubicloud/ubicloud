# Terraform generator: brief for the rebuild

The generator in `lib/terraform_generator` is a prototype. It shows that
the provider can be generated from clover, and how to test it, but its
abstractions carry special cases where they should carry rules. The
rebuild uses it as a reference, not as a base. This file records the
decisions that bind the rebuild and the rules that follow from them.

## Decisions

**Clean derivation; the published schema may change.** Daniel Farina,
1 Nov 2026: "Clean derivation. Break path dependency." The prototype
aimed to reproduce the hand-written provider byte for byte, so its
definitions encode that provider's history: vm's `ip4_enabled` is
renamed `enable_ip4`, some attributes are left out to keep the old
schema, and `init_script` stays computed_optional although the spec
marks it writeOnly. The rebuild derives the schema from the spec and
accepts the incompatibility, in a new major version of the provider.
Old spellings do not survive as aliases.

**The test path must be easy to use.** Daniel Farina, 1 Nov 2026:
"it's essential the test path be excellent ... in terms of
ergonomics".

**An engineer may edit the generated output and hand it to an LLM to
carry back into the generator.** Daniel Farina, 1 Nov 2026: "LLMs are
great at the detail work of going to post generated state backwards to
generated code. Engineers may make alterations to the materialized
output and then send it to LLm for iterative study."

## Rules

### Derivation

- The spec is the source of truth. When derived output is wrong, fix
  `openapi/openapi.yml` (readOnly, writeOnly, a schema for each request
  and response body, anyOf) before adding to a definition.
- A definition states only what the spec cannot: async waits, the order
  of update verbs, the key that makes create idempotent.
- A DSL word that only one definition uses calls for review: either a
  second resource needs it, or it is a special case that belongs in the
  spec.
- The generic layers name no resource. The prototype builds the
  structs for postgres's config and upgrade status by hand, which is
  why commit 6d964b465 broke it without any check failing.
- Update verbs are data, not one template per verb.
- Go is emitted one way, not partly from Ruby strings and partly from
  ERB.

### Testing

- The derivation (from the spec to the attribute model to the schema)
  is pure Ruby, and has unit specs in the main suite at full coverage.
  `spec/coverage_helper.rb` no longer skips `lib/terraform_generator`.
- Only the terraform runs stay in the separate workflow. Keep the gated
  harness, which runs real terraform against the in-process API and
  holds one request at a gate while the spec checks the database.
- The harness builds the provider binary on every run, so that a stale
  binary is never tested; `go build` caches, so this is cheap.
- One command runs the whole loop, and an engineer can run it without
  first reading the docs.
- `rake terraform:check` also reports a golden that no definition
  produces, and fails if `go mod tidy -diff` would change the module's
  `go.mod`.
- The generated provider's acceptance tests run in clover's CI, so that
  an API change that breaks them fails on the day it lands.

### Carrying changes back from the output

- The loop ends when regeneration reproduces the edited output. An
  empty diff means the change has been carried back completely; any
  diff that remains is the part still to do.
- Generated code says where it came from: a short marker at each block
  names the template, the derivation rule, or the definition's
  attribute.
- A change comes back as one of three things: a change to the spec, a
  fact in a definition, or a general rule. A special case needs review,
  and we keep count of them.
- Output is deterministic, formatted by gofmt, and written one file per
  resource, so that regeneration moves nothing that did not change.
