---- MODULE CSI ----
\* TLA+ Specification of the Ubicloud Kubernetes CSI
\*
\* Models the volume lifecycle, data migration, failure recovery, retry
\* budgets, node-removal blocking, and paging for stuck volumes.
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
\*   - Failed rsync: daemonizer2 unit is cleaned, retry count incremented
\*     on PV annotation, copy restarts from scratch (up to MAX_RETRIES)
\*   - Chained migration: intermediate PV rolled back to Delete, original
\*     source PV annotation preserved on PVC via ||=
\*   - Pod restart: node plugin pod crash/restart is a no-op — daemonizer2
\*     runs on host, backing files on host disk, metadata in K8s API
\*   - Stuck volume paging: check_pulse detects retry count >= MAX_RETRIES
\*     and creates a page for operator intervention
\*
\* Node removal blocking:
\*   After drain, KubernetesNodeNexus waits in wait_for_copy until
\*   pending_pvs is empty.  pending_pvs checks: old-pvc-object annotation,
\*   Retain reclaim policy (excludes rolled-back intermediates), and
\*   nodeAffinity targeting this node.
\*
\* Chained migration fix:
\*   When prepare_data_migration runs and the PVC already has an
\*   old-pv-name annotation, a previous migration was interrupted.
\*   The intermediate PV's reclaim policy is rolled back to Delete,
\*   excluding it from pending_pvs.  trim_pvc uses ||= to preserve
\*   the original source PV name, ensuring rsync copies from the
\*   true data source.  Retry count is reset on the source PV for
\*   the new target.

EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Nodes,          \* Set of worker node identifiers
    Volumes,        \* Set of volume identifiers
    MaxRetries,     \* Maximum migration retry count (matches MAX_MIGRATION_RETRIES = 3)
    NoNode          \* Sentinel: volume not assigned to any node

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
MigFailed   == "MigFailed"     \* rsync failure (recoverable up to MaxRetries)
MigStuck    == "MigStuck"      \* exceeded MaxRetries (needs operator intervention)

\* Node lifecycle states (models KubernetesNodeNexus labels)
NodeActive        == "Active"
NodeDraining      == "Draining"
NodeWaitForCopy   == "WaitForCopy"
NodeRemoved       == "Removed"

ASSUME NoNode \notin Nodes

VARIABLES
    phase,            \* [Volumes -> Phase]
    owner,            \* [Volumes -> Nodes \cup {NoNode}]
    backingFiles,     \* SUBSET (Volumes \X Nodes)
    loopDevices,      \* SUBSET (Volumes \X Nodes)
    stagingMounts,    \* SUBSET (Volumes \X Nodes)
    targetMounts,     \* SUBSET (Volumes \X Nodes)
    nodeSchedulable,  \* [Nodes -> BOOLEAN]
    nodeState,        \* [Nodes -> NodeState] - models node nexus lifecycle
    migState,         \* [Volumes -> MigState]
    migTarget,        \* [Volumes -> Nodes \cup {NoNode}]
    migSource,        \* [Volumes -> Nodes \cup {NoNode}] - original data source node
    migRetryCount,    \* [Volumes -> 0..MaxRetries] - retry attempts consumed
    migReclaimRetain, \* [Volumes -> BOOLEAN] - TRUE when source PV has Retain policy
    paged             \* [Volumes -> BOOLEAN] - whether a page has been created for stuck migration

vars == <<phase, owner, backingFiles, loopDevices, stagingMounts, targetMounts,
          nodeSchedulable, nodeState, migState, migTarget, migSource, migRetryCount,
          migReclaimRetain, paged>>

\* ============================================================
\* Type Invariant
\* ============================================================

TypeOK ==
    /\ phase \in [Volumes -> {Unprovisioned, Created, Staged, Published}]
    /\ owner \in [Volumes -> Nodes \cup {NoNode}]
    /\ backingFiles  \in SUBSET (Volumes \X Nodes)
    /\ loopDevices   \in SUBSET (Volumes \X Nodes)
    /\ stagingMounts \in SUBSET (Volumes \X Nodes)
    /\ targetMounts  \in SUBSET (Volumes \X Nodes)
    /\ nodeSchedulable \in [Nodes -> BOOLEAN]
    /\ nodeState \in [Nodes -> {NodeActive, NodeDraining, NodeWaitForCopy, NodeRemoved}]
    /\ migState  \in [Volumes -> {MigNone, MigPrepared, MigCopying, MigDone, MigFailed, MigStuck}]
    /\ migTarget \in [Volumes -> Nodes \cup {NoNode}]
    /\ migSource \in [Volumes -> Nodes \cup {NoNode}]
    /\ migRetryCount \in [Volumes -> 0..MaxRetries]
    /\ migReclaimRetain \in [Volumes -> BOOLEAN]
    /\ paged \in [Volumes -> BOOLEAN]

\* ============================================================
\* Initial State
\* ============================================================

Init ==
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
    /\ migRetryCount  = [v \in Volumes |-> 0]
    /\ migReclaimRetain = [v \in Volumes |-> FALSE]
    /\ paged          = [v \in Volumes |-> FALSE]

\* ────────────────────────────────────────────────────────────
\* Inline actions follow (extracted from Ruby source via # TLA pragmas)
\* ────────────────────────────────────────────────────────────
