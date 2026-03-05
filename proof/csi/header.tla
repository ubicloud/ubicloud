---- MODULE CSI ----
\* TLA+ Specification of the Ubicloud Kubernetes CSI
\*
\* Models the volume lifecycle, data migration, failure recovery,
\* chained-migration rollback, and node-removal blocking.
\*
\* Volume Lifecycle:
\*   Unprovisioned -> Created -> Staged -> Published
\*                                      -> (Unpublish) Staged
\*                             -> (Unstage) Created
\*                  -> (Delete) Unprovisioned
\*
\* Migration (triggered when node is cordoned during unstage):
\*   1. PV reclaim policy set to Retain, PVC recreated targeting new node
\*   2. Data copied via rsync (async, managed by daemonizer2)
\*   3. New node stages volume with copied data
\*   4. Old backing file cleaned up (reclaim policy reverted to Delete)
\*
\* Recovery mechanisms modeled:
\*   - Failed rsync: daemonizer2 unit is cleaned, CopyNotFinishedError
\*     triggers kubelet retry -> copy restarts from scratch
\*   - Chained migration: intermediate PV rolled back to Delete, original
\*     source PV annotation preserved on PVC via ||=
\*   - Pod restart: node plugin pod crash/restart is a no-op — daemonizer2
\*     runs on host, backing files on host disk, metadata in K8s API
\*
\* Node removal blocking:
\*   After drain, KubernetesNodeNexus waits in wait_for_copy until
\*   pending_pvs is empty.  pending_pvs checks: old-pvc-object annotation,
\*   Retain reclaim policy (excludes rolled-back intermediates), and
\*   nodeAffinity targeting this node.
\*
\* ── Intentional code-proof divergence ──────────────────────────
\*
\* The implementation has a bounded retry budget (MAX_MIGRATION_RETRIES = 3)
\* and a paging mechanism (PageNexus) for stuck migrations.  The proof
\* INTENTIONALLY OMITS these:
\*
\*   Code concept          │ Proof treatment
\*   ──────────────────────┼──────────────────────────────────────
\*   migRetryCount         │ not modeled — retry count is unbounded
\*   MAX_MIGRATION_RETRIES │ not modeled — no retry budget
\*   MigStuck state        │ not modeled — migration always recovers
\*   ExhaustMigrationRetries│ not modeled
\*   PageStuckMigration    │ not modeled
\*   ResolveStuckMigration │ not modeled
\*   paged flag            │ not modeled
\*
\* Rationale: the proof assumes rsync is eventually reliable (transient
\* failures self-heal).  Under this assumption, the retry budget and
\* paging are purely operational safeguards — they cannot fire.  Omitting
\* them lets us prove the stronger liveness property:
\*
\*   "Every created volume eventually reaches Published."
\*
\* The code's retry/page mechanism is a defense-in-depth layer for
\* permanent failures (disk corruption, etc.) that fall outside the
\* fault model of this proof.
\*
\* When reading inline pragmas in node_service.rb and kubernetes_cluster.rb,
\* note that ExhaustMigrationRetries, PageStuckMigration, and retry-count
\* related lines do NOT appear in the proof assembly.

EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Nodes,              \* Set of worker node identifiers
    Volumes,            \* Set of volume identifiers
    NoNode,             \* Sentinel: volume not assigned to any node
    n1, n2, n3          \* Individual node identifiers (for liveness scenarios)

\* Volume lifecycle phases
Unprovisioned == "Unprovisioned"
Created       == "Created"
Staged        == "Staged"
Published     == "Published"

\* Migration states
MigNone     == "MigNone"
MigPrepared == "MigPrepared"
MigCopying  == "MigCopying"
MigDone     == "MigDone"
MigFailed   == "MigFailed"     \* rsync failure (recoverable, unbounded retries)

\* Node lifecycle states (models KubernetesNodeNexus labels)
NodeActive        == "Active"
NodeDraining      == "Draining"
NodeWaitForCopy   == "WaitForCopy"
NodeRemoved       == "Removed"

ASSUME NoNode \notin Nodes

VARIABLES
    phase,            \* [Volumes -> Phase]
    owner,            \* [Volumes -> Nodes \union {NoNode}]
    backingFiles,     \* SUBSET (Volumes \X Nodes)
    loopDevices,      \* SUBSET (Volumes \X Nodes)
    stagingMounts,    \* SUBSET (Volumes \X Nodes)
    targetMounts,     \* SUBSET (Volumes \X Nodes)
    nodeSchedulable,  \* [Nodes -> BOOLEAN]
    nodeState,        \* [Nodes -> NodeState] - models node nexus lifecycle
    migState,         \* [Volumes -> MigState]
    migTarget,        \* [Volumes -> Nodes \union {NoNode}]
    migSource,        \* [Volumes -> Nodes \union {NoNode}] - original data source node
    migReclaimRetain, \* [Volumes -> BOOLEAN] - TRUE when source PV has Retain policy
    scenarioPhase     \* STRING - liveness scenario phase ("done" for safety)

vars == <<phase, owner, backingFiles, loopDevices, stagingMounts, targetMounts,
          nodeSchedulable, nodeState, migState, migTarget, migSource,
          migReclaimRetain, scenarioPhase>>

\* ============================================================
\* Type Invariant
\* ============================================================

TypeOK ==
    /\ phase \in [Volumes -> {Unprovisioned, Created, Staged, Published}]
    /\ owner \in [Volumes -> Nodes \union {NoNode}]
    /\ backingFiles  \in SUBSET (Volumes \X Nodes)
    /\ loopDevices   \in SUBSET (Volumes \X Nodes)
    /\ stagingMounts \in SUBSET (Volumes \X Nodes)
    /\ targetMounts  \in SUBSET (Volumes \X Nodes)
    /\ nodeSchedulable \in [Nodes -> BOOLEAN]
    /\ nodeState \in [Nodes -> {NodeActive, NodeDraining, NodeWaitForCopy, NodeRemoved}]
    /\ migState  \in [Volumes -> {MigNone, MigPrepared, MigCopying, MigDone, MigFailed}]
    /\ migTarget \in [Volumes -> Nodes \union {NoNode}]
    /\ migSource \in [Volumes -> Nodes \union {NoNode}]
    /\ migReclaimRetain \in [Volumes -> BOOLEAN]
    /\ scenarioPhase \in {"done", "cordon_n1", "drain_n1", "wait_for_mig"}

\* ============================================================
\* Initial State
\* ============================================================

BaseInit ==
    /\ phase          = [v \in Volumes |-> Unprovisioned]
    /\ owner          = [v \in Volumes |-> NoNode]
    /\ backingFiles   = {}
    /\ loopDevices    = {}
    /\ stagingMounts  = {}
    /\ targetMounts   = {}
    /\ nodeSchedulable = [n \in Nodes |-> TRUE]
    /\ nodeState      = [n \in Nodes |-> NodeActive]
    /\ migState       = [v \in Volumes |-> MigNone]
    /\ migTarget      = [v \in Volumes |-> NoNode]
    /\ migSource      = [v \in Volumes |-> NoNode]
    /\ migReclaimRetain = [v \in Volumes |-> FALSE]

Init == BaseInit /\ scenarioPhase = "done"

\* ────────────────────────────────────────────────────────────
\* Inline actions follow (extracted from Ruby source via # TLA pragmas)
\* ────────────────────────────────────────────────────────────
