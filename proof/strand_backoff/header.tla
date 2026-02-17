---- MODULE StrandBackoff ----
\* Extended strand scheduling model with exponential backoff, crash
\* recovery, time passage, LEAST-based signaling, parent-child
\* scheduling, and hop+deadline semantics.
\*
\* Builds on StrandSchedule by adding concrete schedule values,
\* a try counter, Crash, Tick, ChildExit, and HopAndDeadline.
\*
\* Strand lifecycle per run:
\*   TAKE_LEASE_PS (autocommit) -> DB.transaction { SemSnap -> label -> outcome }
\*
\* Outcomes:
\*   NapCommit        -- label raised Nap(seconds); try=0, conditional schedule
\*   HopAndDeadline   -- label raised Hop, inner loop timed out; try=0,
\*                       schedule stays at TAKE_LEASE_PS value
\*   Crash            -- transaction rolls back; TAKE_LEASE_PS effects persist
\*                       (try already incremented, schedule = backoff value)
\*
\* Schedule semantics (integer countdown):
\*   > 0  = future (not eligible for pickup)
\*   = 0  = now (eligible)
\*   < 0  = past-due / overdue (eligible, higher priority in dispatcher)
\*   Hibernate = sentinel (strand sleeps until signaled)
\*
\* TAKE_LEASE_PS pre-increments try:
\*   try' = try + 1  (autocommit, persists on crash)
\*   schedule' = Backoff(try')
\*   Production: LEAST(2^LEAST(try,20), 600) * random()
\*   Abstract:   Backoff(t) == t  (monotonic, sufficient for properties)
\*
\* Nap handler conditional UPDATE (the lost-wake fix):
\*   SET schedule = CASE WHEN schedule = $expected THEN nap_time
\*                       ELSE schedule END
\*   $expected = value TAKE_LEASE_PS set = Backoff(try)
\*   If Signal changed schedule, CASE falls through, preserving the signal.
\*
\* NapDetectsAllInterference (key insight):
\*   During active phase, Backoff(try) >= 1 (because Wake pre-increments
\*   try from 0 to at least 1).  Signal/ChildExit set schedule to at most 0
\*   via LEAST.  Therefore schedule = Backoff(try) is true IFF no external
\*   actor modified schedule -- no false positives, no false negatives.
\*   The pre-increment in TAKE_LEASE_PS is safety-critical: without it,
\*   Backoff(0) = 0 collides with Signal's LEAST value.
\*
\* Signal (Semaphore.incr) uses LEAST:
\*   schedule = LEAST(schedule, NOW())
\*   Never increases schedule -- preserves overdue priority ordering.
\*   Also models self-incr (@snap.incr in Prog::Base), which goes through
\*   the same CTE and has identical scheduling effects.
\*
\* ChildExit: parent scheduling on child strand exit.
\*   Strand.where(id: parent_id).update(schedule: LEAST(schedule, NOW()))
\*   Like Signal but without a semaphore insertion.
\*
\* Tick models time passage while idle:
\*   schedule decrements by 1 (future -> now -> overdue).
\*   Hibernate is immune to Tick (only Signal/ChildExit can wake it).

EXTENDS Integers

CONSTANTS
  MaxTry,       \* maximum try counter (caps Backoff growth)
  MaxSignals,   \* total signals bound (for finite model checking)
  MaxNap,       \* maximum nap duration
  Hibernate     \* sentinel: strand sleeps until signaled

ASSUME Hibernate > MaxTry + MaxNap + 1

VARIABLES
  phase,        \* "idle" | "active"
  schedule,     \* Int: countdown to eligibility (see semantics above)
  try,          \* 0..MaxTry: backoff counter (pre-incremented by Wake)
  pending,      \* unprocessed semaphore count
  visible,      \* semaphores captured by SemSnap at Wake time
  totalSigs     \* total signals sent (bounded for model checking)

vars == <<phase, schedule, try, pending, visible, totalSigs>>

\* ---- Helpers ----

\* Abstract monotonic backoff function.
\* Production: LEAST(2^LEAST(try,20), 600) * random()
\* Abstract: identity (monotonic, non-zero for try >= 1).
Backoff(t) == t

\* Lower bound on schedule for finite state space.
\* Allows modeling overdue strands (negative schedule).
MinSchedule == -(MaxSignals + 1)

\* All valid nap durations including hibernate.
NapDurations == (1..MaxNap) \cup {Hibernate}

\* LEAST(schedule, 0): pulls schedule to now, preserves overdue priority.
Least0(s) == IF s > 0 THEN 0 ELSE s

\* ---- Type invariant ----

TypeOK ==
  /\ phase \in {"idle", "active"}
  /\ schedule \in MinSchedule..Hibernate
  /\ try \in 0..MaxTry
  /\ pending \in 0..MaxSignals
  /\ visible \in 0..MaxSignals
  /\ totalSigs \in 0..MaxSignals
