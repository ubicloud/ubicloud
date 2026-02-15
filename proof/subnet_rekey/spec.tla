\* AbortRekey: all locked NICs destroyed mid-rekey → abort to idle.
\* Models the `if nics.empty?` fast-path in wait_inbound/outbound/old_drop.
AbortRekey(s) ==
  /\ pc[s] \in {"phase_inbound", "phase_outbound", "phase_old_drop"}
  /\ heldLocks[s] = {}
  /\ pc' = [pc EXCEPT ![s] = "idle"]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded>>

----

ASSUME MaxRefresh >= 2 * MaxOps + 1

Init ==
  /\ edges = {}
  /\ pc = [s \in Subnets |-> "idle"]
  /\ heldLocks = [s \in Subnets |-> {}]
  /\ ops = 0
  /\ nicPhase = [n \in AllNics |-> "idle"]
  /\ activeNics = InitActiveNics
  /\ refreshNeeded = [s \in Subnets |-> FALSE]

Next ==
  \/ \E a, b \in Subnets : ConnectSubnets(a, b)
  \/ \E a, b \in Subnets : DisconnectSubnets(a, b)
  \/ \E s \in Subnets : EnterAndLock(s)
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
\* SF on EnterAndLock and ForwardRefreshKeys — both have guards that
\* flicker under contention (another coordinator repeatedly locks/unlocks
\* shared NICs, topology changes under signal forwarding).  WF does not
\* guarantee progress when enablement is intermittent; SF does.
\* All other actions are continuously enabled once their pc guard holds,
\* so WF suffices.
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
       /\ SF_vars(EnterAndLock(s))
       /\ SF_vars(ForwardRefreshKeys(s))

----

\* ---- Safety properties ----

TypeOK ==
  /\ edges \subseteq Edge
  /\ pc \in [Subnets -> {"idle", "phase_inbound",
                          "phase_outbound", "phase_old_drop"}]
  /\ \A s \in Subnets : heldLocks[s] \subseteq AllNics
  /\ ops \in 0..MaxOps
  /\ nicPhase \in [AllNics -> {"idle", "inbound", "outbound", "old_drop"}]
  /\ activeNics \subseteq AllNics
  /\ refreshNeeded \in [Subnets -> BOOLEAN]

\* MutualExclusion: no NIC is locked by two subnets simultaneously.
MutualExclusion ==
  \A n \in AllNics :
    \A s1, s2 \in Subnets :
      (n \in heldLocks[s1] /\ n \in heldLocks[s2]) => s1 = s2

\* NoOrphanedLocks: subnet in idle has no locked NICs.
NoOrphanedLocks ==
  \A s \in Subnets :
    pc[s] = "idle" => heldLocks[s] = {}

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
      nicPhase[n] \in CASE pc[s] = "phase_inbound"  -> {"idle", "inbound"}
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

\* RefreshEventuallyConsumed: every refresh request eventually gets processed.
RefreshEventuallyConsumed ==
  \A s \in Subnets : refreshNeeded[s] ~> ~refreshNeeded[s]

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
