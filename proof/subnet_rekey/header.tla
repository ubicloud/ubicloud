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
  MaxOps,           \* Nat — bounds topology/lifecycle operations
  MaxRefresh        \* Nat — bounds refreshNeeded counter (for TLC)

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
