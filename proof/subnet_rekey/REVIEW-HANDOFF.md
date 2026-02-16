# SubnetRekey Review Handoff (Round 2)

Itemized findings from five parallel review agents (2026-02-16).
Work through in discussion, log resolutions below each item.

---

## A. Spec Fixes

### A1. PhaseCoordinatorAlignment CASE has no OTHER arm
**Severity: CRITICAL**

The CASE expression in PhaseCoordinatorAlignment has no `[] OTHER ->` clause.
If a bug ever puts a locked NIC under an idle coordinator, TLC crashes with a
runtime error instead of cleanly reporting the invariant violation. Currently
safe because NoOrphanedLocks prevents the state, but the invariant should be
self-contained.

**Fix:** Add `[] OTHER -> {"idle"}` to the CASE arms.

**Resolution:**

### A2. Remove dead FairSpec
**Severity: MINOR**

`FairSpec` is defined in spec.tla but never referenced by any config.
`ProgressSpec` is the authoritative fairness specification (upgrades
EnterAndLock and ForwardRefreshKeys to SF). FairSpec creates confusion
about which fairness spec is authoritative.

**Fix:** Remove FairSpec or add a comment explaining it is the weaker
variant preserved for reference.

**Resolution:**

### A3. Add ASSUME for MaxRefresh vs MaxOps relationship
**Severity: MINOR**

If someone misconfigures `MaxRefresh` too low, TypeOK fires instead of
RefreshBounded, masking the real bound. The relationship
`MaxRefresh >= 2 * MaxOps + 1` should be asserted.

**Fix:** Add `ASSUME MaxRefresh >= 2 * MaxOps + 1` to spec.tla.

**Resolution:**

### A4. ops \in Nat is imprecise in TypeOK
**Severity: STYLE**

`ops \in Nat` is correct but TLC-unfriendly. `0..MaxOps` would be more
precise and serve as documentation of the actual reachable range.

**Resolution:**

---

## B. Config Fixes

### B1. InactiveNicsIdle defined but not in any safety config
**Severity: HIGH**

`InactiveNicsIdle` is defined in spec.tla (line 122) but not listed as
`INVARIANT` in any `.cfg` file. A future code change that removes a NIC
from `activeNics` without resetting its `nicPhase` would go undetected.
`NoPhaseWithoutLock` only checks active NICs, so it cannot catch this
class of bug.

**Fix:** Add `INVARIANT InactiveNicsIdle` to all safety configs.

**Resolution:**

---

## C. Mutation Tests

### C1. Missing outbound barrier mutation
**Severity: HIGH**

Only the inbound barrier is tested (skip-inbound-barrier). The 3-phase
protocol has 3 symmetric barriers. The outbound barrier
(`\A n \in heldLocks[s] : nicPhase[n] = "outbound"` in AdvanceOutbound)
is completely untested. Expected violation: PhaseCoordinatorAlignment.

**Resolution:**

### C2. Missing old_drop barrier mutation in FinishRekey
**Severity: HIGH**

FinishRekey has `\A n \in heldLocks[s] : nicPhase[n] = "old_drop"` guard.
This is the third barrier and gates lock release. Expected violation:
NoPhaseWithoutLock (or possibly PhaseCoordinatorAlignment).

**Resolution:**

### C3. Missing NicAdvanceOldDrop pc guard mutation
**Severity: MEDIUM**

Symmetric to existing skip-nic-pc-guard (which targets NicAdvanceOutbound).
Removing the `pc[s] = "phase_old_drop"` check from NicAdvanceOldDrop should
violate PhaseCoordinatorAlignment.

**Resolution:**

### C4. RefreshBounded has zero mutation coverage
**Severity: MEDIUM**

No mutation specifically targets RefreshBounded. Proposed: remove the
`refreshNeeded' = [refreshNeeded EXCEPT ![s] = 0]` drain in EnterAndLock,
which should cause unbounded re-entry and violate RefreshBounded.

**Resolution:**

### C5. AbortRekey empty-guard mutation
**Severity: MEDIUM**

NoOrphanedLocks has only 1 mutation (skip-unlock). Removing the
`heldLocks[s] = {}` precondition from AbortRekey should violate
NoOrphanedLocks since locks are not released in AbortRekey's UNCHANGED.

**Resolution:**

### C6. Destroy idle-guard mutation
**Severity: LOW**

The `before_run` guard is documented as proof-critical for NoOrphanedLocks.
No mutation tests removing the `pc[s] = "idle"` guard from Destroy. May
pass (benign) but worth verifying.

**Resolution:**

### C7. Fragility: mutations #3 and #4 share identical find strings
**Severity: LOW**

skip-unlock and skip-phase-reset both target the same two lines in
FinishRekey with different replacements. Works because `.sub` hits the
first match, but fragile under refactoring.

**Resolution:**

---

## D. Ruby Hardening

### D1. FinishRekey released count assertion too strict
**Severity: MINOR (but fires in production)**

`locked_nics` is fetched, then `locked_nics_dataset.update(...)` runs.
A concurrent `DestroyNic` between fetch and update means fewer rows
updated, triggering `fail "BUG: released #{released} NICs"` during
normal operation.

**Fix:** Allow `released <= nics.count && released > 0`.

**Resolution:**

### D2. Re-check leader after FOR UPDATE in refresh_keys
**Severity: MAJOR (liveness gap)**

`connected_leader?` check and `nics_to_rekey.for_update` are separate
queries. Topology can change between them. FOR UPDATE prevents
double-locking (MutualExclusion safe), but the coordinator could lock
NICs from a split-off component.

**Fix:** Re-check `connected_leader?` after acquiring row locks; bounce
back to wait if no longer leader.

**Resolution:**

### D3. Guard nics.empty? in refresh_keys
**Severity: MINOR**

If no active/creating NICs exist, code proceeds through all barrier
phases with an empty set before AbortRekey fires. Add early return:

```ruby
if nics.empty?
  private_subnet.update(state: "waiting")
  hop_wait
end
```

**Resolution:**

### D4. DestroyNic: incr_refresh_keys fires before nic.destroy
**Severity: MINOR (inverted from proof)**

Proof models DestroyNic atomically. Ruby sends the refresh signal
first, then destroys the NIC. Signal ordering is inverted from proof.
Within a strand transaction it's safe, but semantically inverted.

**Resolution:**

### D5. NIC state filter fragility
**Severity: LOW**

`nics_to_rekey` filters by `%w[active creating]` corresponding to TLA+
`activeNics`. Adding a new NIC state that should participate in rekey
would silently diverge from proof. Consider a class constant:

```ruby
REKEY_ACTIVE_STATES = %w[active creating].freeze
```

**Resolution:**

### D6. FK comment says RESTRICT but constraint is NO ACTION
**Severity: LOW (cosmetic)**

Comment in nic_nexus.rb says "FK is RESTRICT" but Sequel's
`add_foreign_key` without `on_delete:` creates NO ACTION (default).
Functionally equivalent for non-deferred constraints, but imprecise.

**Resolution:**

---

## E. Design Observations (No Action Needed)

### E1. Two concurrent coordinators in merged component
ConnectSubnets can merge two components each with an active coordinator.
MutualExclusion handles the safety — FOR UPDATE prevents double-locking.
No invariant asserts single-coordinator-per-component, but violations
are benign (handled by existing invariants).

### E2. EnterAndLock allows empty NIC set
`AllConnectedNics(s) = {}` when all NICs destroyed. Vacuously passes
lock check, enters rekey with nothing to do. AbortRekey catches it.
Over-approximation that strengthens the proof.

### E3. Destroyed subnets persist as ghosts
TLA+ `Subnets` is a constant; destroyed subnets remain. Conservative —
the proof explores more behaviors than Ruby, strengthening safety.

### E4. All proof-source divergences are over-approximations
The proof-source alignment review found no CRITICAL or MAJOR issues.
Every divergence is either an intentional over-approximation (proof
explores more states than Ruby) or a documented assumption boundary.

### E5. Garbled comment in assembled output
The `before_run` destroy guard comment from subnet_nexus.rb gets
concatenated with the ForwardRefreshKeys pragma during assembly.
Cosmetic issue in generated output only.

---

## Resolution Log

| Date | Item | Decision | Notes |
|------|------|----------|-------|
