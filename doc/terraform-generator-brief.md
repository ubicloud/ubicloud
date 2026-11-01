# Terraform generator: brief for the rebuild

A prototype of the generator is in pull request
https://github.com/ubicloud/ubicloud/pull/6331, on the branch
terraform-generator-prototype. It shows that the provider can be
generated from clover, and how to test it, but its abstractions carry
special cases where they should carry rules. The rebuild uses it as a
reference, not as a base. This file records the decisions that bind
the rebuild and the rules that follow from them.

## Decisions

**Clean derivation; the published schema may change.** Daniel Farina,
1 Nov 2026: "Clean derivation. Break path dependency." The prototype
aimed to reproduce the hand-written provider byte for byte, so its
definitions encode that provider's history: vm's `ip4_enabled` is
renamed `enable_ip4`, some attributes are left out to keep the old
schema, and `init_script` stays computed_optional although the spec
marks it writeOnly. The rebuild derives the schema from the spec and
accepts the incompatibility, in a new major version of the provider.
The provider keeps no old spelling as an alias, although the API keeps
the old request names for a while.

**The test path must be easy to use.** Daniel Farina, 1 Nov 2026:
"it's essential the test path be excellent ... in terms of
ergonomics".

**An engineer may edit the generated output and hand it to an LLM to
carry back into the generator.** Daniel Farina, 1 Nov 2026: "LLMs are
great at the detail work of going to post generated state backwards to
generated code. Engineers may make alterations to the materialized
output and then send it to LLm for iterative study."

**One consistent definition for every resource, without overfitting.**
Daniel Farina, 1 Nov 2026: "we want consistency and elegance in
definition for all resources, avoiding over fit. Current prototype
proves "something" is possible already". The rebuild need not prove
feasibility again; it starts from the shape every definition shares.

**The API may change for elegance.** Daniel Farina, 1 Nov 2026: "free
changes for elegance. Assume that the resources are not already
perfect." Changes to the spec and to the API behind it are part of the
rebuild, not work that must be done before it.

**The published provider is not a reference either.** Daniel Farina,
1 Nov 2026: "it's the version this was based on, with Postgres specific
weaknesses / hacks there in."

**Users re-import; there is no state migration.** Daniel Farina,
1 Nov 2026: "re import. Carry no path dependency." The new provider has
no state upgrader for state written by the old one.

**The rebuild lives on a new local branch until it is ready for
review.** Daniel Farina decided on 1 Nov 2026 that the branch is kept
as a git bundle meanwhile.

**The prototype does not merge.** Daniel Farina also decided on
1 Nov 2026 that the terraform suite, being slow, may run as its own
GitHub workflow, and that the main suite's coverage may be split among
jobs.

**The API may break existing clients where no additive change can remove
a fault.** Daniel Farina, 2 Nov 2026, answering whether creating a
Postgres metric destination may return the destination rather than its
database, and whether Postgres may refuse the legacy `burstable-*` sizes
rather than rewrite them: "yes".

**A name is the idempotency key of a create.** Daniel Farina, 2 Nov
2026: "the name is the idempotency key for create at least, even as it
has a system generated id", and "The idea name is the key." When the
outcome of a create is unknown, the provider looks the object up by
name and adopts it, even if it existed before the apply; there is no
`Idempotency-Key` header. For a type without a name he chose "(A) for
unnamed entities": the provider reports the problem and suggests an
import. The API keeps refusing a repeated create: "We do use a 400 code
on retry."

**CI always runs the terraform suite and checks its coverage; the
everyday loop stays fast.** Daniel Farina, 2 Nov 2026: "Ci should
always run and qualify coverage, it's more it should not slow normal day
to day engineer loops". As for the Go code: "You can target 100% in
go, though, I suspect it won't be easy: harder than in Ruby. At times
we may augment with custom tests for specific important regressions."

**The first cut follows the design's recommendations.** Daniel Farina,
2 Nov 2026, accepting them: "Sure 14 types. Sure, extensions. Sure, gke
pattern. Sure, use modern terraform and use sensitive." So the first
cut has fourteen types; `x-lifecycle` and `x-immutable` are part of the
spec; a kubernetes cluster can be created without a nodepool, and can
lose its last one; inputs the API never echoes are kept in state,
marked sensitive where the spec says `format: password`; and the
provider targets current terraform rather than an old minimum version.

**Release and versioning wait until we see what the break costs.**
Daniel Farina, 2 Nov 2026: "Don't worry about release structure yet, or
version. Let's list see how brutal non backward compatible change looks
before worrying about it, to see what the cleanliness picked up is. It
may be okay to commit it into clover." Once the types are generated, we
compare the old provider and API with the new ones, to see what the
incompatibility costs and what it buys. Whether to commit the generated
module was settled later that day: it is not committed.

**The generator is a separate program.** Daniel Farina, 2 Nov 2026:
"lib/terraform_generator really shouldn't load in production: it's not
dynamic. It's really just a whole separate program with connected
resources akin to the kubernetes csi. If it needs a new top level
directory, that's fine. the tricky part is tying it together with the
test suite infrastructure." And: "the csi doesn't have any interesting
software engineering in this regard other than being another program
"along side" in some sense. this one is harder because it needs test
integration with the api server, so I wouldn't read too much into csi
organization". The generator, its specs and the Go engine live in a
top-level `terraform/` directory, which clover never loads; the harness,
which runs terraform against the API in process, lives in clover's
`spec/terraform/`.

**The generated output is not committed, and the harness comes first.**
Daniel Farina, 2 Nov 2026: "we don't need to commit the materialized
output." Asked whether the generator's specs should run only in the
terraform workflow: "yes, that's it, people working on terraform will
know. The hard part is how to integrate the test system with the api
implementation itself. this is the core priority, so terraform
misbehaviors can be written in ruby rspec."

**Renamed request fields keep aliases until a new API version.** Daniel
Farina, 2 Nov 2026: "we can use yet-unexercised versioning for this, the
new version can be consistent. We do have an accept header idea
somewhere to do this. and yes, use aliases in the interim." And: "maybe
it was just an intention, because the project is based on the Heroku
stack and Wesley Beary's work and the pliny tradition. But we've been
playing it a bit fast and loose with API stability so far. These changes
are too large to ignore though, they'd need us to implement something."
Then: "I think we should both implement aliases, deprecation warnings
(based on statistical failing of requests at some point with a
message), plus a version based on accept that only accepts new,
normalized fields." So the API gets three things: aliases for the old
names; warnings to clients that use them, and later a fraction of their
requests refused with a message saying what to send instead; and a
version, chosen by the Accept header in the pliny manner, that accepts
only the new names. The purpose reaches beyond this rebuild: "basically
we should use these extra constraints to keep better alignment with
norms in the future." The norms are checked mechanically, so that later
changes to the API keep to them.

**The harness settles objects with hooks, and runs no progs.** Daniel
Farina, 2 Nov 2026: "Generally we do not write tests for cross label /
convergence phenomena for progs: combinatoric explosion under
composition. How does this case compare?" Running each object's progs
to rest would make every harness example such a test, against a
simulated data plane. The harness tests the provider against the states
the API reports, which `x-lifecycle` declares, so it stubs at that
boundary: after the API accepts a change, a hook for the affected table
puts its rows into the resting state. He replied: "Great, sounds like
you have something to think about now".

**Deleting code is a high priority.** Daniel Farina, 2 Nov 2026, on the
harness once it runs no progs: "You should aim to delete a lot of
mechanism with that restriction in place. You surely did a lot to try
it out. Deleting code is a high priority as we think". Mechanism that a
decision makes unnecessary, or that only an experiment needed, goes.

**Everything is set up to run locally.** Daniel Farina, 2 Nov 2026: "set
up everything locally; this software has a good model locally, the only
thing you can't really do is e2e and testing github actions itself."

**Objects in a response nest until a schema repeats.** Jeremy Evans
asked, in review of the prototype
(https://github.com/ubicloud/ubicloud/pull/6331#discussion_r4342893994),
that a VM's listing of its firewalls show each rule's protocol, which
nesting one level leaves out. Offered "(a) Keep the one-level rule" and
"(b) Stop where a schema repeats, not at a fixed depth", Daniel Farina
answered on 5 Nov 2026: "(b)". So the nesting stops where a schema
already on the path recurs.

**Provenance comments are pointers, not prose.** Daniel Farina, 5 Nov
2026: "comments can be extremely short and cryptic for back-tracing",
and "think: closer to debug symbols than for human legibility (so ruby
file, or a line, or a method, something practical here)". Each comment
names the generator's method and the spec location, in the shortest
form that an engineer or an LLM can follow back, and no line number,
which would move with every edit to the generator.

## Rules

### Derivation

- The spec is the source of truth. When derived output is wrong, fix
  `openapi/openapi.yml` (readOnly, writeOnly, a schema for each request
  and response body, anyOf) before adding to a definition.
- A definition states only what the spec cannot, such as the order of
  update verbs.
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
  is pure Ruby, and its unit specs cover it fully. Clover's main suite
  neither loads nor runs it.
- The terraform workflow runs the generator's specs, the Go engine's
  tests and the harness. Keep the gated harness, which runs real
  terraform against the in-process API and holds one request at a gate
  while the spec checks the database; a terraform misbehaviour is
  written as an rspec example in it.
- The harness builds the provider binary on every run, so that a stale
  binary is never tested; `go build` caches, so this is cheap.
- One command runs the whole loop, and an engineer can run it without
  first reading the docs.
- `rake terraform:check` also reports a generated file that no
  definition produces, and fails if `go mod tidy -diff` would change
  the module's `go.mod`.
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
  fact in a definition, or a general rule. Each special case needs
  review, and we keep count of them.
- Output is deterministic, formatted by gofmt, and written one file per
  resource, so that regeneration moves nothing that did not change.
