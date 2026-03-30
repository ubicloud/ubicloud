
\* ---- Environment: time passage ----

\* Tick: time passes while the strand is idle.
\* Decrements schedule toward eligibility (0).
\* Hibernate is immune: only Signal/ChildExit can wake a hibernating strand.
Tick ==
  /\ phase = "idle"
  /\ schedule > MinSchedule
  /\ schedule # Hibernate
  /\ schedule' = schedule - 1
  /\ UNCHANGED <<phase, try, pending, visible, totalSigs>>

\* ---- Specification ----

\* A successful run: NapCommit or HopAndDeadline (both consume and reset try).
SuccessfulRun == (\E n \in NapDurations : NapCommit(n)) \/ HopAndDeadline

Init ==
  /\ phase = "idle"
  /\ schedule = 0
  /\ try = 0
  /\ pending = 0
  /\ visible = 0
  /\ totalSigs = 0

Next ==
  \/ Wake
  \/ \E n \in NapDurations : NapCommit(n)
  \/ HopAndDeadline
  \/ Crash
  \/ Signal
  \/ ChildExit
  \/ Tick

\* Fairness:
\*   WF(Tick)  -- time always passes for idle strands
\*   WF(Wake)  -- eligible strands eventually get picked up
\*   SF(SuccessfulRun) -- strand can't crash forever; eventually succeeds
\*     (SF because crashes temporarily disable SuccessfulRun via idle phase,
\*      but it's repeatedly enabled on each Wake; SF ensures eventual success)
\*   No fairness on Signal, ChildExit, Crash (external/failure events)
Fairness ==
  /\ WF_vars(Tick)
  /\ WF_vars(Wake)
  /\ SF_vars(SuccessfulRun)

Spec == Init /\ [][Next]_vars /\ Fairness

\* Variant: assumes the environment keeps signaling (WF on Signal).
\* Used to check SignalAlwaysWakes, which requires environmental cooperation.
SignalSpec == Init /\ [][Next]_vars /\ Fairness /\ WF_vars(Signal)

\* ---- Safety invariants ----

\* Core property: a hibernating idle strand has no pending semaphores.
\* If this holds, hibernate is safe -- every signal wakes the strand.
NoLostWake ==
  ~(phase = "idle" /\ schedule = Hibernate /\ pending > 0)

\* Backoff bound: during active phase, schedule <= Backoff(try).
\* Signal/ChildExit can only decrease schedule (via LEAST).
\* Wake sets schedule = Backoff(try) exactly.
\* Therefore schedule = Backoff(try) iff no interference occurred.
ActiveScheduleBound ==
  phase = "active" => schedule <= Backoff(try)

\* Interference detection: the conditional's "expected" value Backoff(try)
\* is strictly positive during active phase (try >= 1 from Wake's pre-increment).
\* Since Signal/ChildExit produce values <= 0 via LEAST, the conditional
\* schedule = Backoff(try) is a perfect discriminator:
\*   TRUE  => no interference (safe to set nap/hibernate)
\*   FALSE => interference occurred (preserve Signal's schedule)
\* This is why the pre-increment is safety-critical: Backoff(0) = 0 would
\* collide with Signal's LEAST value, creating false negatives.
NapDetectsAllInterference ==
  phase = "active" => Backoff(try) > 0

\* ---- Liveness properties ----

\* Every signal is eventually consumed (requires bounded totalSigs).
SignalsConsumed ==
  (pending > 0) ~> (pending = 0)

\* A non-hibernating idle strand with positive schedule eventually wakes.
\* Verified by: Tick decrements schedule to 0, then Wake fires.
CrashRecovery ==
  (phase = "idle" /\ schedule > 0 /\ schedule # Hibernate) ~> (phase = "active")

\* A hibernating strand that can be signaled is eventually woken.
\* Verified by: Signal sets schedule = LEAST(Hibernate, 0) = 0, then Wake fires.
SignalAlwaysWakes ==
  (phase = "idle" /\ schedule = Hibernate /\ totalSigs < MaxSignals) ~> (phase = "active")

====
