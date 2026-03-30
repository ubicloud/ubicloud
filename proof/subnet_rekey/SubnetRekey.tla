---- MODULE SubnetRekey ----
\* Subnet NIC rekeying coordination proof.
\*
\* Models subnet_nexus.rb#refresh_keys: multiple subnets in a
\* connected mesh can attempt lock acquisition concurrently.
\* FOR UPDATE row locks prevent double-locking (MutualExclusion),
\* but do not lock the topology tables — ConnectedLeader(s) can
\* change between lock acquisition and the leadership re-check.
\* This seam is modeled as two steps: ReadAndLock (acquire locks,
\* pc "idle" → "refresh_keys") and ClaimOrBail (validate leadership,
\* "refresh_keys" → "phase_inbound" or bail to "idle").
\*
\* Additionally models:
\*   - NIC creation and destruction during rekey cycles
\*   - Rekey triggering via refreshNeeded (semaphore model)
\*   - Phase enum matching the nic.rekey_phase column
\*
\* Safety: FOR UPDATE row locks prevent double-locking.
\* Liveness: leader election prevents starvation (one coordinator
\* per connected component).

EXTENDS Naturals, FiniteSets

CONSTANTS
  Subnets,          \* Set of subnet IDs (Nat, for leader ordering)
  AllNics,          \* Set of all possible NIC IDs (universe for TLC)
  NicOwner,         \* [AllNics -> Subnets] — static ownership (NICs never migrate between subnets)
  InitActiveNics,   \* SUBSET AllNics — initially active NICs
  MaxOps            \* Nat — bounds topology/lifecycle operations

VARIABLES
  edges,            \* SUBSET Edge — connected_subnet graph
  pc,               \* [Subnets -> PcStates] — coordinator state
  heldLocks,        \* [Subnets -> SUBSET AllNics] — NICs locked by coordinator
  ops,              \* Nat — operation counter
  nicPhase,         \* [AllNics -> NicPhases] — nic.rekey_phase column
  activeNics,       \* SUBSET AllNics — currently existing NICs
  refreshNeeded     \* [Subnets -> Nat] — pending refresh_keys semaphore count

vars == <<edges, pc, heldLocks, ops, nicPhase, activeNics, refreshNeeded>>

\* ---- Topology helpers ----

\* Ordered edge representation (a < b).
Edge == {<<a, b>> \in Subnets \X Subnets : a < b}

\* NICs owned by subnet s (active only).
NicsOf(s) == {n \in activeNics : NicOwner[n] = s}

\* Neighbors of x via undirected edges.
Neighbors(x) == {t \in Subnets : <<x, t>> \in edges \/ <<t, x>> \in edges}

\* Transitive closure: all subnets reachable from s (BFS).
RECURSIVE Reach(_, _)
Reach(todo, done) ==
  IF todo = {} THEN done
  ELSE LET x == CHOOSE x \in todo : TRUE
           new == Neighbors(x) \ done
       IN Reach((todo \ {x}) \union new, done \union new)

ConnectedComponent(s) == Reach({s}, {s})

\* Connected leader: smallest-ID subnet in the component.
ConnectedLeader(s) ==
  CHOOSE x \in ConnectedComponent(s) :
    \A y \in ConnectedComponent(s) : x <= y

\* All NICs across the connected component of s (active only).
AllConnectedNics(s) == UNION {NicsOf(t) : t \in ConnectedComponent(s)}

\* NIC lock check: true if any subnet holds a lock on n.
IsLocked(n) == \E s \in Subnets : n \in heldLocks[s]

\* ---- NicOwner definitions (for TLC config <- override) ----

\* 2-subnet, 4 NICs: NICs 1,2 -> subnet 1; NICs 3,4 -> subnet 2
NicOwner_2S == [n \in {1, 2, 3, 4} |-> IF n <= 2 THEN 1 ELSE 2]

\* 3-subnet, 5 NICs: NIC 1 -> subnet 1; NICs 2,3 -> subnet 2; NICs 4,5 -> subnet 3
NicOwner_3S == [n \in {1, 2, 3, 4, 5} |-> IF n = 1 THEN 1 ELSE IF n <= 3 THEN 2 ELSE 3]

\* 4-subnet, 8 NICs: 2 per subnet
NicOwner_4S8 == [n \in 1..8 |-> IF n <= 2 THEN 1 ELSE IF n <= 4 THEN 2 ELSE IF n <= 6 THEN 3 ELSE 4]

\* 5-subnet, 8 NICs: subnets 1-3 get 2 NICs, subnets 4,5 get 1
NicOwner_5S == [n \in 1..8 |-> IF n <= 2 THEN 1 ELSE IF n <= 4 THEN 2 ELSE IF n <= 6 THEN 3 ELSE n - 3]

\* 3-subnet, 6 NICs: 2 per subnet — moderate width stress
NicOwner_3S6 == [n \in 1..6 |-> IF n <= 2 THEN 1 ELSE IF n <= 4 THEN 2 ELSE 3]

\* 3-subnet dense, 9 NICs: 3 per subnet — barrier stress + 3-way contention
NicOwner_3Sd == [n \in 1..9 |-> IF n <= 3 THEN 1 ELSE IF n <= 6 THEN 2 ELSE 3]

\* 6-subnet sparse, 4 NICs: 2 subnets with NICs, 4 empty — topology stress
NicOwner_6Sp == [n \in 1..4 |-> IF n <= 2 THEN 1 ELSE 2]

\* 8-subnet, 10 NICs: 1 per subnet + extras on subnets 1,2
NicOwner_8S == [n \in 1..10 |-> IF n <= 2 THEN 1 ELSE IF n <= 4 THEN 2 ELSE n - 2]

----
\* ConnectSubnets: add edge — unrestricted, can happen mid-rekey.
\* Sets refreshNeeded on both subnets (Ruby: subnet.incr_refresh_keys).
ConnectSubnets(a, b) ==
  /\ a \in Subnets /\ b \in Subnets /\ a < b
  /\ <<a, b>> \notin edges
  /\ ops < MaxOps
  /\ edges' = edges \union {<<a, b>>}
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![a] = @ + 1, ![b] = @ + 1]
  /\ ops' = ops + 1
  /\ UNCHANGED <<pc, heldLocks, nicPhase, activeNics>>

\* DisconnectSubnets: remove edge.  Both sides get refreshNeeded.
DisconnectSubnets(a, b) ==
  /\ <<a, b>> \in edges
  /\ ops < MaxOps
  /\ edges' = edges \ {<<a, b>>}
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![a] = @ + 1, ![b] = @ + 1]
  /\ ops' = ops + 1
  /\ UNCHANGED <<pc, heldLocks, nicPhase, activeNics>>

\* Destroy guard: subnet cannot be destroyed while heldLocks[s] # {}.
\* Proof-critical for NoOrphanedLocks invariant.
\* ForwardRefreshKeys: non-leader forwards refreshNeeded to leader.
\* Models wait: decr_refresh_keys + connected_leader.incr_refresh_keys.
ForwardRefreshKeys(s) ==
  /\ pc[s] = "idle"
  /\ refreshNeeded[s] > 0
  /\ ConnectedLeader(s) # s
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![s] = 0, ![ConnectedLeader(s)] = @ + 1]
  /\ UNCHANGED <<edges, pc, heldLocks, ops, nicPhase, activeNics>>

\* ConsumeRefresh: idle → consumed.  Drain refreshNeeded (wait:decr_refresh_keys).
\* Models the wait label consuming the semaphore before hop_refresh_keys.
\* At "consumed", the signal is consumed but no locks are held.
ConsumeRefresh(s) ==
  /\ pc[s] = "idle"
  /\ ConnectedLeader(s) = s
  /\ refreshNeeded[s] > 0
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![s] = 0]
  /\ pc' = [pc EXCEPT ![s] = "consumed"]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics>>

\* BailRefresh: consumed → idle.  Bail from refresh_keys label.
\* Re-enqueues refreshNeeded unless leader with empty component (nothing to rekey).
\* Three bail paths below map to the three guard disjuncts.
BailRefresh(s) ==
  /\ pc[s] = "consumed"
  /\ \/ ConnectedLeader(s) # s
    \/ AllConnectedNics(s) = {}
    \/ \E n \in AllConnectedNics(s) : IsLocked(n)
  /\ pc' = [pc EXCEPT ![s] = "idle"]
  /\ refreshNeeded' = IF ConnectedLeader(s) = s /\ AllConnectedNics(s) = {}
                     THEN refreshNeeded
                     ELSE [refreshNeeded EXCEPT ![s] = @ + 1]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics>>

\* ReadAndLock: consumed → refresh_keys.  Acquire NIC row locks (FOR UPDATE).
\* All bail paths above have exited; guards all passed.
\* FOR UPDATE does not lock topology tables; ConnectedLeader can change
\* before ClaimOrBail re-checks leadership.
ReadAndLock(s) ==
  /\ pc[s] = "consumed"
  /\ ConnectedLeader(s) = s
  /\ LET nics == AllConnectedNics(s)
    IN /\ nics # {}
       /\ \A n \in nics : ~IsLocked(n)
       /\ heldLocks' = [heldLocks EXCEPT ![s] = nics]
  /\ pc' = [pc EXCEPT ![s] = "refresh_keys"]
  /\ UNCHANGED <<edges, ops, nicPhase, activeNics, refreshNeeded>>

\* ClaimOrBail: refresh_keys → phase_inbound (proceed) or idle (bail).
\* Re-checks leadership post-lock; topology may have changed since ReadAndLock.
\* ELSE branch is an over-approximation: in Ruby, all bails above have exited
\* and the claim always succeeds within this transaction.
ClaimOrBail(s) ==
  /\ pc[s] = "refresh_keys"
  /\ IF ConnectedLeader(s) = s /\ heldLocks[s] # {}
    THEN /\ pc' = [pc EXCEPT ![s] = "phase_inbound"]
         /\ UNCHANGED <<heldLocks, refreshNeeded>>
    ELSE /\ heldLocks' = [heldLocks EXCEPT ![s] = {}]
         /\ pc' = [pc EXCEPT ![s] = "idle"]
         /\ refreshNeeded' = IF ConnectedLeader(s) # s
                             THEN [refreshNeeded EXCEPT ![s] = @ + 1]
                             ELSE refreshNeeded
  /\ UNCHANGED <<edges, ops, nicPhase, activeNics>>

\* AdvanceInbound: all locked NICs at "inbound" → advance to outbound.
\* Models wait_inbound_setup: checks rekey_phase, triggers outbound.
AdvanceInbound(s) ==
  /\ pc[s] = "phase_inbound"
  /\ heldLocks[s] # {}
  /\ \A n \in heldLocks[s] : nicPhase[n] = "inbound"
  /\ pc' = [pc EXCEPT ![s] = "phase_outbound"]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded>>

\* AdvanceOutbound: all locked NICs at "outbound" → advance to old_drop.
\* Models wait_outbound_setup: checks rekey_phase, triggers old_drop.
AdvanceOutbound(s) ==
  /\ pc[s] = "phase_outbound"
  /\ heldLocks[s] # {}
  /\ \A n \in heldLocks[s] : nicPhase[n] = "outbound"
  /\ pc' = [pc EXCEPT ![s] = "phase_old_drop"]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded>>

\* FinishRekey: phase_old_drop → idle.  Barrier + release all held locks.
\* Resets nicPhase to "idle" for all locked NICs, then releases locks.
FinishRekey(s) ==
  /\ pc[s] = "phase_old_drop"
  /\ heldLocks[s] # {}
  /\ \A n \in heldLocks[s] : nicPhase[n] = "old_drop"
  /\ nicPhase' = [n \in AllNics |-> IF n \in heldLocks[s] THEN "idle" ELSE nicPhase[n]]
  /\ heldLocks' = [heldLocks EXCEPT ![s] = {}]
  /\ pc' = [pc EXCEPT ![s] = "idle"]
  /\ UNCHANGED <<edges, ops, activeNics, refreshNeeded>>

\* Destroy: remove all edges of s, signal neighbors (must be idle with no locks).
\* Models destroy: disconnect_subnet (incr_refresh_keys on both sides) + destroy.
Destroy(s) ==
  /\ pc[s] = "idle"
  /\ heldLocks[s] = {}
  /\ ops < MaxOps
  /\ LET nbrs == Neighbors(s)
    IN /\ edges' = {e \in edges : e[1] # s /\ e[2] # s}
       /\ refreshNeeded' = [t \in Subnets |->
           IF t \in nbrs THEN refreshNeeded[t] + 1 ELSE refreshNeeded[t]]
       /\ ops' = ops + 1
       /\ UNCHANGED <<pc, heldLocks, nicPhase, activeNics>>

\* CreateNic: activate an inactive NIC.  Sets refreshNeeded on owner.
\* Models wait_setup: decr_setup_nic + incr_refresh_keys + state "creating".
CreateNic(n) ==
  /\ n \in AllNics \ activeNics
  /\ ops < MaxOps
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![NicOwner[n]] = @ + 1]
  /\ activeNics' = activeNics \union {n}
  /\ ops' = ops + 1
  /\ UNCHANGED <<edges, pc, heldLocks, nicPhase>>

\* NicAdvanceInbound: idle → inbound (after setup_inbound).
NicAdvanceInbound(n) ==
  /\ n \in activeNics
  /\ nicPhase[n] = "idle"
  /\ \E s \in Subnets : n \in heldLocks[s] /\ pc[s] = "phase_inbound"
  /\ nicPhase' = [nicPhase EXCEPT ![n] = "inbound"]
  /\ UNCHANGED <<edges, pc, heldLocks, ops, activeNics, refreshNeeded>>

\* NicAdvanceOutbound: inbound → outbound (after setup_outbound).
NicAdvanceOutbound(n) ==
  /\ n \in activeNics
  /\ nicPhase[n] = "inbound"
  /\ \E s \in Subnets : n \in heldLocks[s] /\ pc[s] = "phase_outbound"
  /\ nicPhase' = [nicPhase EXCEPT ![n] = "outbound"]
  /\ UNCHANGED <<edges, pc, heldLocks, ops, activeNics, refreshNeeded>>

\* NicAdvanceOldDrop: outbound → old_drop (after drop_old_state).
NicAdvanceOldDrop(n) ==
  /\ n \in activeNics
  /\ nicPhase[n] = "outbound"
  /\ \E s \in Subnets : n \in heldLocks[s] /\ pc[s] = "phase_old_drop"
  /\ nicPhase' = [nicPhase EXCEPT ![n] = "old_drop"]
  /\ UNCHANGED <<edges, pc, heldLocks, ops, activeNics, refreshNeeded>>

\* DestroyNic: deactivate an active NIC.  Removes from heldLocks (FK cascade).
\* Models destroy: nic.destroy + incr_refresh_keys.
DestroyNic(n) ==
  /\ n \in activeNics
  /\ ops < MaxOps
  /\ activeNics' = activeNics \ {n}
  /\ heldLocks' = [s \in Subnets |-> heldLocks[s] \ {n}]
  /\ nicPhase' = [nicPhase EXCEPT ![n] = "idle"]
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![NicOwner[n]] = @ + 1]
  /\ ops' = ops + 1
  /\ UNCHANGED <<edges, pc>>

\* AbortRekey: all locked NICs destroyed mid-rekey → abort to idle.
\* Models the `if nics.empty?` fast-path in wait_inbound/outbound/old_drop.
AbortRekey(s) ==
  /\ pc[s] \in {"phase_inbound", "phase_outbound", "phase_old_drop"}
  /\ heldLocks[s] = {}
  /\ pc' = [pc EXCEPT ![s] = "idle"]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded>>

----

Init ==
  /\ edges = {}
  /\ pc = [s \in Subnets |-> "idle"]
  /\ heldLocks = [s \in Subnets |-> {}]
  /\ ops = 0
  /\ nicPhase = [n \in AllNics |-> "idle"]
  /\ activeNics = InitActiveNics
  /\ refreshNeeded = [s \in Subnets |-> 0]

Next ==
  \/ \E a, b \in Subnets : ConnectSubnets(a, b)
  \/ \E a, b \in Subnets : DisconnectSubnets(a, b)
  \/ \E s \in Subnets : ConsumeRefresh(s)
  \/ \E s \in Subnets : ReadAndLock(s)
  \/ \E s \in Subnets : BailRefresh(s)
  \/ \E s \in Subnets : ClaimOrBail(s)
  \/ \E n \in AllNics : NicAdvanceInbound(n)
  \/ \E n \in AllNics : NicAdvanceOutbound(n)
  \/ \E n \in AllNics : NicAdvanceOldDrop(n)
  \/ \E s \in Subnets : AdvanceInbound(s)
  \/ \E s \in Subnets : AdvanceOutbound(s)
  \/ \E s \in Subnets : FinishRekey(s)
  \/ \E s \in Subnets : AbortRekey(s)
  \/ \E s \in Subnets : ForwardRefreshKeys(s)
  \/ \E n \in AllNics : CreateNic(n)
  \/ \E n \in AllNics : DestroyNic(n)
  \/ \E s \in Subnets : Destroy(s)

Spec == Init /\ [][Next]_vars

\* ProgressSpec: the system makes progress under contention.
\*
\* ── WF disjunction technique ──────────────────────────────────────────
\*
\* When two actions A and B have complementary guards (exactly one is
\* always enabled at a given pc state), their disjunction A \/ B is
\* continuously enabled.  WF_vars(A \/ B) then guarantees the step is
\* eventually taken — sufficient to prove "eventually leave this state,"
\* which is all the leads-to liveness properties need.  SF_vars(A) /\
\* SF_vars(B) would also suffice, but each SF condition can double the
\* Buchi automaton's acceptance pairs (O(2^k) for k SF conditions vs
\* O(k) for k WF conditions), exceeding TLC's hardcoded DNF limit.
\*
\* Requirement: no action other than A or B can leave the pc state.
\* The individual guards may toggle freely (e.g. ConnectedLeader changes
\* via topology actions) — only the *disjunction* must stay enabled.
\*
\* ── Application here ──────────────────────────────────────────────────
\*
\* IdleRefreshProgress: at pc="idle" with refreshNeeded>0, exactly one of
\* ConsumeRefresh (leader) or ForwardRefreshKeys (non-leader) is enabled.
\* The disjunction is continuously enabled (only they can zero refreshNeeded
\* or move pc from "idle"), so WF suffices.
\*
\* ConsumedProgress: at pc="consumed", ReadAndLock and BailRefresh are
\* complementary (guards are exact negations).  The disjunction is
\* continuously enabled (no other action changes pc from "consumed"), WF.
\*
\* ClaimOrBail is continuously enabled at pc="refresh_keys", WF.
IdleRefreshProgress(s) == ConsumeRefresh(s) \/ ForwardRefreshKeys(s)
ConsumedProgress(s)    == ReadAndLock(s) \/ BailRefresh(s)

ProgressSpec == Spec
  /\ \A n \in AllNics :
       /\ WF_vars(NicAdvanceInbound(n))
       /\ WF_vars(NicAdvanceOutbound(n))
       /\ WF_vars(NicAdvanceOldDrop(n))
  /\ \A s \in Subnets :
       /\ WF_vars(AdvanceInbound(s))
       /\ WF_vars(AdvanceOutbound(s))
       /\ WF_vars(FinishRekey(s))
       /\ WF_vars(AbortRekey(s))
       /\ WF_vars(ClaimOrBail(s))
       /\ WF_vars(IdleRefreshProgress(s))
       /\ WF_vars(ConsumedProgress(s))

----

\* ---- Safety properties ----

TypeOK ==
  /\ edges \subseteq Edge
  /\ pc \in [Subnets -> {"idle", "consumed", "refresh_keys", "phase_inbound",
                          "phase_outbound", "phase_old_drop"}]
  /\ \A s \in Subnets : heldLocks[s] \subseteq AllNics
  /\ ops \in 0..MaxOps
  /\ nicPhase \in [AllNics -> {"idle", "inbound", "outbound", "old_drop"}]
  /\ activeNics \subseteq AllNics
  /\ refreshNeeded \in [Subnets -> Nat]

\* MutualExclusion: no NIC is locked by two subnets simultaneously.
MutualExclusion ==
  \A n \in AllNics :
    \A s1, s2 \in Subnets :
      (n \in heldLocks[s1] /\ n \in heldLocks[s2]) => s1 = s2

\* NoOrphanedLocks: subnet in idle or consumed has no locked NICs.
NoOrphanedLocks ==
  \A s \in Subnets :
    pc[s] \in {"idle", "consumed"} => heldLocks[s] = {}

\* LockedNicsActive: destroyed NICs cannot remain locked.
LockedNicsActive ==
  \A s \in Subnets : heldLocks[s] \subseteq activeNics

\* NoPhaseWithoutLock: unlocked active NICs must be at "idle" phase.
NoPhaseWithoutLock ==
  \A n \in activeNics :
    ~IsLocked(n) => nicPhase[n] = "idle"

\* PhaseCoordinatorAlignment: locked NIC's phase is consistent with coordinator's pc.
PhaseCoordinatorAlignment ==
  \A n \in AllNics : \A s \in Subnets :
    n \in heldLocks[s] =>
      nicPhase[n] \in CASE pc[s] = "refresh_keys"   -> {"idle"}
                        [] pc[s] = "phase_inbound"   -> {"idle", "inbound"}
                        [] pc[s] = "phase_outbound"  -> {"inbound", "outbound"}
                        [] pc[s] = "phase_old_drop"  -> {"outbound", "old_drop"}
                        [] OTHER                     -> {"idle"}

\* RefreshBounded: semaphore count bounded by 2*MaxOps.
\* Each impulse signals at most 2 subnets; with drain semantics, the worst case
\* is MaxOps impulses each paired with a forward to the leader: 2*MaxOps.
RefreshBounded ==
  \A s \in Subnets : refreshNeeded[s] <= 2 * MaxOps

\* InactiveNicsIdle: destroyed/unborn NICs always have idle phase.
\* Complements NoPhaseWithoutLock: together, only active locked NICs
\* can have non-idle phase.
InactiveNicsIdle ==
  \A n \in AllNics \ activeNics : nicPhase[n] = "idle"

\* ---- Liveness properties ----

\* RekeyCompletes: every rekey eventually finishes.
RekeyCompletes == \A s \in Subnets : pc[s] /= "idle" ~> pc[s] = "idle"

\* RefreshEventuallyConsumed: every refresh request eventually gets fully consumed.
RefreshEventuallyConsumed ==
  \A s \in Subnets : refreshNeeded[s] > 0 ~> refreshNeeded[s] = 0

\* EventualQuiescence: after all topology/lifecycle impulses, system settles.
\* Impulses (connect, disconnect, create, destroy) can arrive at any time
\* and interleave freely with rekey processing.  MaxOps bounds the total
\* impulse count for TLC; the convergence is structural (drain semantics +
\* no derivative signals from FinishRekey) and independent of MaxOps.
EventualQuiescence ==
  ops = MaxOps ~> (\A s \in Subnets : pc[s] = "idle" /\ refreshNeeded[s] = 0)

\* NicPhaseProgress: every NIC with pending crypto eventually settles.
\* NIC-level complement to RekeyCompletes (coordinator-level): a NIC in
\* non-idle phase has partial crypto state that must be resolved — either
\* by FinishRekey (normal), DestroyNic (cascade), or AbortRekey (empty set).
NicPhaseProgress ==
  \A n \in AllNics : (n \in activeNics /\ nicPhase[n] /= "idle") ~> nicPhase[n] = "idle"

\* LocksEventuallyReleased: no NIC stays locked forever.
\* A stuck lock blocks all future rekeys for the entire connected component.
LocksEventuallyReleased ==
  \A n \in AllNics : IsLocked(n) ~> ~IsLocked(n)

====
