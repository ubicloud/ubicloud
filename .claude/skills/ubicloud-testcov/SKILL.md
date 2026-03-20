---
name: ubicloud-testcov
description: Iteratively fix test coverage gaps in the Ubicloud codebase until line and branch coverage both reach 100%.
user-invocable: true
---

# Ubicloud Test Coverage Skill

You are working to achieve 100% line and branch coverage in the Ubicloud test suite. Work autonomously, iterating until both metrics reach 100%, then validate with the frozen run.

Always run commands from the current project root.

## Step 1 — Run coverage

```bash
bundle exec rake coverage
```

This auto-selects serial or parallel (turbo_tests) based on whether `.auto-parallel-tests` exists, cleans `coverage/views` automatically, and reports line and branch percentages at the end:

```
Line Coverage: 99.99% (19018 / 19019)
Branch Coverage: 99.91% (5603 / 5608)
```

**Success:** both show `100.0%`. Stop here — proceed to Step 4 (frozen validation).

## Step 2 — Find gaps

**For human review (highlighted output):**
```bash
ruby .claude/skills/ubicloud-testcov/find-gaps.rb | ruby .claude/skills/ubicloud-testcov/highlight-gaps.rb
```

`find-gaps.rb` reads `coverage/.resultset.json` and emits one tab-separated record per gap (lines and branches not inside `# :nocov:` blocks). `highlight-gaps.rb` renders that output with ANSI colour: uncovered lines in red, uncovered branch expressions highlighted in yellow with the branch type labelled.

**Raw output (for programmatic use / further processing):**
```bash
ruby .claude/skills/ubicloud-testcov/find-gaps.rb
```

Raw format:
```
LINE    routes/billing.rb    19
BRANCH  lib/overrider.rb     17    6    77    :else
BRANCH  lib/overrider.rb     18    6    63    :then
```
Fields: `TYPE  file  lineno  [start_col  end_col  branch_type]`

## Step 3 — Fix each gap

Work through gaps one at a time. For each gap:

### Read the source and understand the code path

Use the `Read` tool. Identify what condition leads to this branch and whether it represents real, reachable behavior.

### Decision: add a test OR remove the code

**Add a test** when:
- The path represents real behavior (error case, edge case, conditional feature)
- A test can exercise it without excessive mocking

**Remove the code** when:
- It is dead/redundant — e.g., a nil-check that framework middleware (Committee/OpenAPI) already enforces before the route runs, or a defensive guard that is logically impossible to reach
- Removing it makes the code cleaner without losing any real protection

**`# :nocov:` is a last resort only** for code that is:
- Genuinely unreachable in tests due to environment differences (e.g. production-only config, platform-specific paths)
- Already validated at a higher layer AND cannot be removed without losing clarity

Always prefer fixing the code over marking it uncoverable.

### Find the right spec file

| Source file | Spec file |
|---|---|
| `routes/billing.rb` | `spec/routes/api/billing_spec.rb` |
| `model/foo.rb` | `spec/model/foo_spec.rb` |
| `prog/foo/bar_nexus.rb` | `spec/prog/foo/bar_nexus_spec.rb` |
| `helpers/foo.rb` | `spec/helpers/foo_spec.rb` or covered via route specs |
| `lib/foo.rb` | `spec/lib/foo_spec.rb` |
| `override/prog/foo.rb` | covered via the corresponding prog spec |

### Write targeted tests

Keep tests minimal and focused on the specific uncovered path.

**API route tests** — must reference `project` let to set up PAT auth:
```ruby
it "rejects unknown project" do
  project  # sets up PAT auth header
  get "/billing/resources?...&project_id=#{other.ubid}"
  expect(last_response.status).to eq(400)
end
```

**Prog specs** — use the standard fixtures from the describe block:
```ruby
it "covers the missing branch" do
  postgres_server
  postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "env", "value" => "prod"}]))
  expect { nx.update_billing_records }.to hop("wait")
  expect(BillingRecord.first.tags["env"]).to eq("prod")
end
```

### Verify the fix before moving on

Run just the affected spec file using the pre-approved script:
```bash
.claude/skills/ubicloud-testcov/run-spec.sh <spec_file>
# or with a specific line:
.claude/skills/ubicloud-testcov/run-spec.sh <spec_file>:<line>
```

Confirm 0 failures before moving to the next gap.

## Step 4 — Validate frozen behavior

Once coverage is 100%/100%, run the full suite in frozen mode (mirrors production):

```bash
bundle exec rake frozen_spec
```

All examples must pass with 0 failures. If any fail, investigate and fix — frozen mode failures are real bugs.

## Iteration loop

```
rake coverage → 100%/100%? → yes → rake frozen_spec → done
                            ↓ no
               find-gaps.rb → read source → add test or remove dead code
                            → run-spec.sh <file> → repeat
```

## Notes on common gap patterns

- **`lib/overrider.rb` lines 17-18**: `PrependMethods` / `PrependClassMethods` detection. Both branches need an override file that defines each. The `PrependClassMethods` branch is hit when an override defines class-level methods.
- **`routes/billing.rb` nil guards**: If Committee OpenAPI validation enforces required params, the nil-check in route code is dead — remove it rather than nocov-ing it.
- **`helpers/model_hiding.rb` else branches**: The else branch of the main `if Config.unfrozen_test?` block runs in frozen/production — it's legitimately untestable in unfrozen mode, so `# :nocov:` is appropriate there.
- **`override/` files**: The override hook body only runs when fixtures include the relevant data (e.g. non-empty tags array). Update the fixture, not the test logic.
- **Branch vs line**: A branch can be uncovered even when the line is covered (e.g. `unless x` — the line runs but the raise never fires). The branch tool output shows both sides; find which side is 0.
