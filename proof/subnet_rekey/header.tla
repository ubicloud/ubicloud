---- MODULE SubnetRekey ----
\* Subnet NIC rekeying coordination proof.
\*
\* Models subnet_nexus.rb#refresh_keys: multiple subnets in a
\* connected mesh can attempt lock acquisition concurrently.
\* Lock acquisition is atomic (FOR UPDATE row locks on coordinator FK).
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
  refreshNeeded     \* [Subnets -> BOOLEAN] — pending refresh_keys semaphore

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

----
\* ConnectSubnets: add edge — unrestricted, can happen mid-rekey.
\* Sets refreshNeeded on both subnets (Ruby: subnet.incr_refresh_keys).
ConnectSubnets(a, b) ==
  /\ a \in Subnets /\ b \in Subnets /\ a < b
  /\ <<a, b>> \notin edges
  /\ ops < MaxOps
  /\ edges' = edges \union {<<a, b>>}
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![a] = TRUE, ![b] = TRUE]
  /\ ops' = ops + 1
  /\ UNCHANGED <<pc, heldLocks, nicPhase, activeNics>>

\* DisconnectSubnets: remove edge.  Both sides get refreshNeeded.
DisconnectSubnets(a, b) ==
  /\ <<a, b>> \in edges
  /\ ops < MaxOps
  /\ edges' = edges \ {<<a, b>>}
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![a] = TRUE, ![b] = TRUE]
  /\ ops' = ops + 1
  /\ UNCHANGED <<pc, heldLocks, nicPhase, activeNics>>

\* ForwardRefreshKeys: non-leader forwards refreshNeeded to leader.
\* Models wait: decr_refresh_keys + connected_leader.incr_refresh_keys.
ForwardRefreshKeys(s) ==
  /\ pc[s] = "idle"
  /\ refreshNeeded[s]
  /\ ConnectedLeader(s) # s
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![s] = FALSE, ![ConnectedLeader(s)] = TRUE]
  /\ UNCHANGED <<edges, pc, heldLocks, ops, nicPhase, activeNics>>

\* EnterAndLock: idle → phase_inbound.  Atomic read + lock.
\* Leader election ensures one coordinator per component (liveness).
\* FOR UPDATE + coordinator check: row locks serialize the read-check-claim.
\* Note: refreshNeeded' consumed earlier in wait:decr_refresh_keys.
EnterAndLock(s) ==
  /\ pc[s] = "idle"
  /\ ConnectedLeader(s) = s
  /\ LET nics == AllConnectedNics(s)
    IN /\ \A n \in nics : ~IsLocked(n)
       /\ heldLocks' = [heldLocks EXCEPT ![s] = nics]
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![s] = FALSE]
  /\ pc' = [pc EXCEPT ![s] = "phase_inbound"]
  /\ UNCHANGED <<edges, ops, nicPhase, activeNics>>

\* AdvanceInbound: all locked NICs at "inbound" → advance to outbound.
\* Models wait_inbound_setup: checks rekey_phase, triggers outbound.
AdvanceInbound(s) ==
  /\ pc[s] = "phase_inbound"
  /\ \A n \in heldLocks[s] : nicPhase[n] = "inbound"
  /\ pc' = [pc EXCEPT ![s] = "phase_outbound"]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded>>

\* AdvanceOutbound: all locked NICs at "outbound" → advance to old_drop.
\* Models wait_outbound_setup: checks rekey_phase, triggers old_drop.
AdvanceOutbound(s) ==
  /\ pc[s] = "phase_outbound"
  /\ \A n \in heldLocks[s] : nicPhase[n] = "outbound"
  /\ pc' = [pc EXCEPT ![s] = "phase_old_drop"]
  /\ UNCHANGED <<edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded>>

\* FinishRekey: phase_old_drop → idle.  Barrier + release all held locks.
\* Resets nicPhase to "idle" for all locked NICs, then releases locks.
\* Signals released NICs' owners to wake competing coordinators.
FinishRekey(s) ==
  /\ pc[s] = "phase_old_drop"
  /\ \A n \in heldLocks[s] : nicPhase[n] = "old_drop"
  /\ nicPhase' = [n \in AllNics |-> IF n \in heldLocks[s] THEN "idle" ELSE nicPhase[n]]
  /\ heldLocks' = [heldLocks EXCEPT ![s] = {}]
  /\ refreshNeeded' = [t \in Subnets |->
      IF t # s /\ \E n \in heldLocks[s] : NicOwner[n] = t
      THEN TRUE
      ELSE refreshNeeded[t]]
  /\ pc' = [pc EXCEPT ![s] = "idle"]
  /\ UNCHANGED <<edges, ops, activeNics>>

\* Destroy: remove all edges of s (must be idle with no locks).
Destroy(s) ==
  /\ pc[s] = "idle"
  /\ heldLocks[s] = {}
  /\ ops < MaxOps
  /\ edges' = {e \in edges : e[1] # s /\ e[2] # s}
  /\ ops' = ops + 1
  /\ UNCHANGED <<pc, heldLocks, nicPhase, activeNics, refreshNeeded>>

\* CreateNic: activate an inactive NIC.  Sets refreshNeeded on owner.
\* Models wait_setup: decr_setup_nic + incr_refresh_keys + state "creating".
CreateNic(n) ==
  /\ n \in AllNics \ activeNics
  /\ ops < MaxOps
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![NicOwner[n]] = TRUE]
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
  /\ refreshNeeded' = [refreshNeeded EXCEPT ![NicOwner[n]] = TRUE]
  /\ activeNics' = activeNics \ {n}
  /\ heldLocks' = [s \in Subnets |-> heldLocks[s] \ {n}]
  /\ nicPhase' = [nicPhase EXCEPT ![n] = "idle"]
  /\ ops' = ops + 1
  /\ UNCHANGED <<edges, pc>>

