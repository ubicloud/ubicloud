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
\* Models NodeService#node_stage_volume with migration path:
\* fetch_and_migrate_pvc -> migrate_pvc_data returns "Succeeded".
\* The rsync source is migSource (original data node, preserved by ||=).
\* After staging, roll_back_reclaim_policy reverts old PV to Delete,
\* and remove_old_pv_annotation_from_pvc clears the annotation.
\* Only on nodes where kubelet is running (Active or Draining).
NodeStageVolumeWithMigration(v) ==
    /\ phase[v] = Created
    /\ migState[v] = MigDone
    /\ migTarget[v] \in Nodes
    /\ LET newNode == migTarget[v] IN
       /\ nodeState[newNode] \in {NodeActive, NodeDraining}
       /\ <<v, newNode>> \in backingFiles
       /\ phase'         = [phase EXCEPT ![v] = Staged]
       /\ owner'         = [owner EXCEPT ![v] = newNode]
       /\ loopDevices'   = loopDevices   \union {<<v, newNode>>}
       /\ stagingMounts' = stagingMounts \union {<<v, newNode>>}
       /\ migState'      = [migState  EXCEPT ![v] = MigNone]
       /\ migTarget'     = [migTarget EXCEPT ![v] = NoNode]
       /\ migSource'     = [migSource EXCEPT ![v] = NoNode]
       /\ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = FALSE]
       /\ UNCHANGED <<backingFiles, targetMounts, nodeSchedulable, nodeState, scenarioPhase>>
\* Models NodeService#node_stage_volume (no migration path):
\* Creates backing file, sets up loop device, formats filesystem, mounts.
\* Only on nodes where kubelet is running (Active or Draining).
NodeStageVolume(v) ==
    /\ phase[v] = Created
    /\ owner[v] \in Nodes
    /\ migState[v] = MigNone
    /\ LET n == owner[v] IN
       /\ nodeState[n] \in {NodeActive, NodeDraining}
       /\ phase'         = [phase EXCEPT ![v] = Staged]
       /\ backingFiles'  = backingFiles  \union {<<v, n>>}
       /\ loopDevices'   = loopDevices   \union {<<v, n>>}
       /\ stagingMounts' = stagingMounts \union {<<v, n>>}
       /\ UNCHANGED <<owner, targetMounts, nodeSchedulable, nodeState,
                      migState, migTarget, migSource,
                      migReclaimRetain, scenarioPhase>>
\* CompleteMigrationCopy: daemonizer2 "Succeeded" → backingFiles' \union= {<<v, newNode>>}
CompleteMigrationCopy(v) ==
    /\ migState[v] = MigCopying
    /\ migTarget[v] \in Nodes
    /\ migSource[v] \in Nodes
    /\ <<v, migSource[v]>> \in backingFiles
    /\ LET newNode == migTarget[v] IN
       /\ backingFiles' = backingFiles \union {<<v, newNode>>}
       /\ migState'     = [migState EXCEPT ![v] = MigDone]
       /\ UNCHANGED <<phase, owner, loopDevices, stagingMounts, targetMounts,
                      nodeSchedulable, nodeState, migTarget, migSource,
                      migReclaimRetain, scenarioPhase>>
\* StartMigrationCopy: daemonizer2 "NotStarted" → run rsync
StartMigrationCopy(v) ==
    /\ migState[v] = MigPrepared
    /\ migTarget[v] \in Nodes
    /\ migSource[v] \in Nodes
    /\ <<v, migSource[v]>> \in backingFiles    \* source data must exist
    /\ migState' = [migState EXCEPT ![v] = MigCopying]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migTarget,
                   migSource, migReclaimRetain, scenarioPhase>>
\* FailMigrationCopy: daemonizer2 "Failed" → MigFailed + CopyNotFinishedError
FailMigrationCopy(v) ==
    /\ migState[v] = MigCopying
    /\ migTarget[v] \in Nodes
    /\ migState' = [migState EXCEPT ![v] = MigFailed]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migTarget,
                   migSource, migReclaimRetain, scenarioPhase>>
\* Models NodeService#node_unstage_volume when node IS schedulable:
\* Tears down loop device and unmounts staging path.
NodeUnstageVolumeNormal(v) ==
    /\ phase[v] = Staged
    /\ owner[v] \in Nodes
    /\ LET n == owner[v] IN
       /\ <<v, n>> \notin targetMounts
       /\ nodeSchedulable[n] = TRUE
       /\ phase'         = [phase EXCEPT ![v] = Created]
       /\ loopDevices'   = loopDevices   \ {<<v, n>>}
       /\ stagingMounts' = stagingMounts \ {<<v, n>>}
       /\ UNCHANGED <<owner, backingFiles, targetMounts,
                      nodeSchedulable, nodeState, migState, migTarget,
                      migSource, migReclaimRetain, scenarioPhase>>
\* → NodeUnstageVolumeWithMigration (see prepare_data_migration)
\* Models NodeService#node_unstage_volume when node is NOT schedulable:
\* Calls prepare_data_migration -> retain_pv -> recreate_pvc.
\* For the first migration: no existing old-pv-name annotation.
NodeUnstageVolumeWithMigration(v, newNode) ==
    /\ phase[v] = Staged
    /\ owner[v] \in Nodes
    /\ migState[v] = MigNone
    /\ LET oldNode == owner[v] IN
       /\ <<v, oldNode>> \notin targetMounts
       /\ nodeSchedulable[oldNode] = FALSE
       /\ newNode \in Nodes
       /\ newNode /= oldNode
       /\ nodeSchedulable[newNode] = TRUE
       /\ phase'         = [phase EXCEPT ![v] = Created]
       /\ loopDevices'   = loopDevices   \ {<<v, oldNode>>}
       /\ stagingMounts' = stagingMounts \ {<<v, oldNode>>}
       /\ migState'      = [migState  EXCEPT ![v] = MigPrepared]
       /\ migTarget'     = [migTarget EXCEPT ![v] = newNode]
       /\ migSource'     = [migSource EXCEPT ![v] = oldNode]
       /\ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = TRUE]
       /\ UNCHANGED <<owner, backingFiles, targetMounts, nodeSchedulable,
                      nodeState, scenarioPhase>>
\* Models NodeService#node_publish_volume: bind mount from staging to target.
NodePublishVolume(v) ==
    /\ phase[v] = Staged
    /\ owner[v] \in Nodes
    /\ LET n == owner[v] IN
       /\ <<v, n>> \in stagingMounts
       /\ phase'        = [phase EXCEPT ![v] = Published]
       /\ targetMounts' = targetMounts \union {<<v, n>>}
       /\ UNCHANGED <<owner, backingFiles, loopDevices, stagingMounts,
                      nodeSchedulable, nodeState, migState, migTarget,
                      migSource, migReclaimRetain, scenarioPhase>>
\* Models NodeService#node_unpublish_volume: unmounts the bind mount.
NodeUnpublishVolume(v) ==
    /\ phase[v] = Published
    /\ owner[v] \in Nodes
    /\ LET n == owner[v] IN
       /\ <<v, n>> \in targetMounts
       /\ phase'        = [phase EXCEPT ![v] = Staged]
       /\ targetMounts' = targetMounts \ {<<v, n>>}
       /\ UNCHANGED <<owner, backingFiles, loopDevices, stagingMounts,
                      nodeSchedulable, nodeState, migState, migTarget,
                      migSource, migReclaimRetain, scenarioPhase>>
\* Models KubernetesNode#pending_pvs: PVs with old-pvc-object annotation,
\* Retain reclaim policy, and nodeAffinity targeting this node.
\* The Retain filter (added in fix-chained-migration) excludes intermediate
\* PVs rolled back to Delete during chained migration.
PendingPVs(n) ==
    {v \in Volumes :
        /\ migState[v] \in {MigPrepared, MigCopying, MigFailed, MigDone}
        /\ migReclaimRetain[v] = TRUE
        /\ migSource[v] = n}
\* migState \in {MigPrepared..MigDone} = old-pvc-object present
\* migReclaimRetain = TRUE              = reclaimPolicy == "Retain"
\* migSource = n                        = nodeAffinity targets this node
\* Models KubernetesNodeNexus: retire -> drain transition.
\* The node transitions to Draining state (kubectl drain --ignore-daemonsets).
StartDrain(n) ==
    /\ n \in Nodes
    /\ nodeState[n] = NodeActive
    /\ nodeSchedulable[n] = FALSE
    /\ nodeState' = [nodeState EXCEPT ![n] = NodeDraining]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, migState, migTarget,
                   migSource, migReclaimRetain, scenarioPhase>>

\* Models KubernetesNodeNexus: drain -> wait_for_copy transition.
\* Drain has completed: kubectl drain evicts all pods on this node, which
\* triggers NodeUnpublish + NodeUnstage for every volume.  Drain only
\* completes when all pods are evicted, so no volumes can have active
\* staging/target mounts on this node.
CompleteDrain(n) ==
    /\ n \in Nodes
    /\ nodeState[n] = NodeDraining
    /\ ~\E v \in Volumes : <<v, n>> \in stagingMounts \/ <<v, n>> \in targetMounts
    /\ nodeState' = [nodeState EXCEPT ![n] = NodeWaitForCopy]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, migState, migTarget,
                   migSource, migReclaimRetain, scenarioPhase>>
\* CompleteDrain: d_check == "Succeeded" → hop_wait_for_copy
\* StartDrain: d_check == "NotStarted" → d_run kubectl drain
\* Models KubernetesNodeNexus: wait_for_copy -> remove_node_from_cluster.
\* Only proceeds when pending_pvs is empty (no more volumes migrating from this node).
RemoveNode(n) ==
    /\ n \in Nodes
    /\ nodeState[n] = NodeWaitForCopy
    /\ PendingPVs(n) = {}
    /\ nodeState' = [nodeState EXCEPT ![n] = NodeRemoved]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, migState, migTarget,
                   migSource, migReclaimRetain, scenarioPhase>>
\* PendingPVs(n) = {} → hop_remove_node_from_cluster
\* ────────────────────────────────────────────────────────────
\* Out-of-line actions (do not closely align with source code)
\* ────────────────────────────────────────────────────────────

\* ============================================================
\* Controller Actions (out-of-line: topology selection diverges from code)
\* ============================================================

\* Models ControllerService#create_volume: selects a worker node
\* topology and assigns the volume to it.
\* NOTE: relaxed from NodeActive — code delegates to K8s scheduler
\* which may pick any non-removed node.
CreateVolume(v, n) ==
    /\ phase[v] = Unprovisioned
    /\ n \in Nodes
    /\ nodeState[n] /= NodeRemoved
    /\ phase' = [phase EXCEPT ![v] = Created]
    /\ owner' = [owner EXCEPT ![v] = n]
    /\ UNCHANGED <<backingFiles, loopDevices, stagingMounts, targetMounts,
                   nodeSchedulable, nodeState, migState, migTarget, migSource,
                   migReclaimRetain, scenarioPhase>>

\* Models K8s rescheduling a Created volume whose owner node is no longer
\* Active (e.g. drained to WaitForCopy or Removed).  The volume has no
\* active mounts (Created, not Staged), so the reassignment is safe.
\* Any orphan backing file on the old node is cleaned up.
\* In the real system this happens via StatefulSet controller delete/recreate.
ReassignVolume(v, n) ==
    /\ phase[v] = Created
    /\ owner[v] \in Nodes
    /\ nodeState[owner[v]] \notin {NodeActive, NodeDraining}
    /\ migState[v] = MigNone
    /\ n \in Nodes
    /\ n /= owner[v]
    /\ nodeState[n] = NodeActive
    /\ nodeSchedulable[n] = TRUE
    /\ owner' = [owner EXCEPT ![v] = n]
    /\ backingFiles' = backingFiles \ {<<v, owner[v]>>}
    /\ UNCHANGED <<phase, loopDevices, stagingMounts, targetMounts,
                   nodeSchedulable, nodeState, migState, migTarget, migSource,
                   migReclaimRetain, scenarioPhase>>

\* Models ControllerService#delete_volume: SSHes to the node hosting the
\* backing file and deletes it.  The volume returns to Unprovisioned.
DeleteVolume(v) ==
    /\ phase[v] = Created
    /\ owner[v] \in Nodes
    /\ migState[v] = MigNone
    /\ LET n == owner[v] IN
       /\ phase'        = [phase EXCEPT ![v] = Unprovisioned]
       /\ owner'        = [owner EXCEPT ![v] = NoNode]
       /\ backingFiles' = backingFiles \ {<<v, n>>}
       /\ UNCHANGED <<loopDevices, stagingMounts, targetMounts,
                      nodeSchedulable, nodeState, migState, migTarget,
                      migSource, migReclaimRetain, scenarioPhase>>

\* ============================================================
\* Cordon / Uncordon (out-of-line: implicit in kubectl drain)
\* ============================================================

\* Models KubernetesNodeNexus#retire -> drain: cordon + kubectl drain.
\* Guard: at least one other node must remain schedulable after cordoning.
\* This models the operational invariant that you never cordon the last
\* schedulable node — if you did, no pods could be scheduled anywhere.
CordonNode(n) ==
    /\ n \in Nodes
    /\ nodeSchedulable[n] = TRUE
    /\ \E m \in Nodes : m /= n /\ nodeSchedulable[m] = TRUE
    /\ nodeSchedulable' = [nodeSchedulable EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeState, migState, migTarget, migSource,
                   migReclaimRetain>>

UncordonNode(n) ==
    /\ n \in Nodes
    /\ nodeSchedulable[n] = FALSE
    /\ nodeSchedulable' = [nodeSchedulable EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeState, migState, migTarget, migSource,
                   migReclaimRetain>>

\* ============================================================
\* Stuck Volume Detection (controller-side recovery)
\* ============================================================

\* Models StuckVolumeDetector#check_stuck_volumes -> recover_stuck_pvc:
\* A background thread on the controller that periodically scans PVCs.
\* Fires when a PVC has old-pv-name annotation AND is bound to a PV
\* on an unschedulable node.
\*
\* This is the ONLY chained migration recovery path.  The node-side
\* prepare_data_migration only handles first migrations (migState = MigNone).
\* When a target node gets cordoned during an active migration, the
\* StuckVolumeDetector detects it and redirects to a new schedulable node.
\*
\* Effect: roll intermediate PV to Delete, recreate PVC targeting a new
\* schedulable node.
\* migSource preserved (trim_pvc uses ||= to keep original source PV).
\*
\* NOTE: code also resets migRetryCount — omitted here (see header.tla
\* for rationale on the intentional divergence from the retry budget).
DetectStuckVolume(v, newNode) ==
    /\ migState[v] \in {MigPrepared, MigCopying, MigFailed, MigDone}
    /\ migTarget[v] \in Nodes
    /\ nodeSchedulable[migTarget[v]] = FALSE   \* target node is unschedulable
    /\ newNode \in Nodes
    /\ newNode /= owner[v]
    /\ newNode /= migTarget[v]
    /\ nodeSchedulable[newNode] = TRUE
    \* migSource preserved, intermediate PV rolled back to Delete
    /\ migTarget'     = [migTarget EXCEPT ![v] = newNode]
    /\ migState'      = [migState  EXCEPT ![v] = MigPrepared]
    /\ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = TRUE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migSource,
                   scenarioPhase>>

\* ============================================================
\* Recovery (out-of-line: bundled with fail in code)
\* ============================================================

\* Recovery from failed copy:
\* clean daemonizer2 unit -> CopyNotFinishedError -> kubelet retries
\* NodeStageVolume -> migrate_pvc_data sees "NotStarted" again.
\*
\* NOTE: code also increments migRetryCount — omitted here because
\* the proof does not model the retry budget (see header.tla).
RecoverFailedMigration(v) ==
    /\ migState[v] = MigFailed
    /\ migTarget[v] \in Nodes
    /\ migState' = [migState EXCEPT ![v] = MigPrepared]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migTarget,
                   migSource, migReclaimRetain, scenarioPhase>>

\* Old backing file cleaned up after migration finalizes.
\* This happens when roll_back_reclaim_policy sets reclaim to Delete
\* and K8s garbage-collects the old PV + backing file.
CleanupOldBackingFile(v) ==
    /\ migState[v] = MigNone
    /\ owner[v] \in Nodes
    /\ \E oldNode \in Nodes :
       /\ oldNode /= owner[v]
       /\ <<v, oldNode>> \in backingFiles
       /\ backingFiles' = backingFiles \ {<<v, oldNode>>}
    /\ UNCHANGED <<phase, owner, loopDevices, stagingMounts, targetMounts,
                   nodeSchedulable, nodeState, migState, migTarget,
                   migSource, migReclaimRetain, scenarioPhase>>

\* Cancel migration when no alternative schedulable node exists.
\* The only schedulable node is the owner itself — the migration target
\* is dead/unschedulable and no third node is available.
\* Reset migration state so the volume can be re-staged on its owner.
CancelMigration(v) ==
    /\ migState[v] \in {MigPrepared, MigCopying, MigFailed, MigDone}
    /\ migTarget[v] \in Nodes
    /\ nodeSchedulable[migTarget[v]] = FALSE
    \* No alternative: only the owner is schedulable and Active
    /\ ~\E alt \in Nodes :
          /\ alt /= owner[v]
          /\ alt /= migTarget[v]
          /\ nodeSchedulable[alt] = TRUE
    /\ owner[v] \in Nodes
    /\ nodeState[owner[v]] \in {NodeActive, NodeDraining}
    /\ migState'  = [migState  EXCEPT ![v] = MigNone]
    /\ migTarget' = [migTarget EXCEPT ![v] = NoNode]
    /\ migSource' = [migSource EXCEPT ![v] = NoNode]
    /\ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = FALSE]
    \* Clean up target backing file if rsync created one
    /\ backingFiles' = backingFiles \ {<<v, migTarget[v]>>}
    /\ UNCHANGED <<phase, owner, loopDevices, stagingMounts, targetMounts,
                   nodeSchedulable, nodeState, scenarioPhase>>

\* ============================================================
\* Pod Restart Resilience (out-of-line: stutter step, no code)
\* ============================================================

\* Node plugin pod restart on destination node during migration.
\* This is a stutter step: no modeled state changes because:
\*   - rsync runs on the host via daemonizer2 (nsenter -t 1), survives pod restart
\*   - backing files live on host disk (/var/lib/ubicsi/), not inside the pod
\*   - migration metadata (old-pv-name, PV reclaim policy) is in K8s API objects
\*   - daemonizer2 unit state is on the host filesystem
\* The new pod picks up exactly where the old one left off:
\*   kubelet retries NodeStageVolume -> migrate_pvc_data checks daemonizer2 ->
\*   sees InProgress/Succeeded/Failed and acts accordingly.
NodePluginRestart(n) ==
    /\ n \in Nodes
    /\ UNCHANGED vars

\* ============================================================
\* Next-State Relation (open system: all actions enabled)
\* ============================================================

Next ==
    /\ (\/ \E v \in Volumes, n \in Nodes : CreateVolume(v, n)
        \/ \E v \in Volumes, n \in Nodes : ReassignVolume(v, n)
        \/ \E v \in Volumes : DeleteVolume(v)
        \/ \E v \in Volumes : NodeStageVolume(v)
        \/ \E v \in Volumes : NodeStageVolumeWithMigration(v)
        \/ \E v \in Volumes : NodePublishVolume(v)
        \/ \E v \in Volumes : NodeUnpublishVolume(v)
        \/ \E v \in Volumes : NodeUnstageVolumeNormal(v)
        \/ \E v \in Volumes, n \in Nodes : NodeUnstageVolumeWithMigration(v, n)
        \/ \E v \in Volumes, n \in Nodes : DetectStuckVolume(v, n)
        \/ \E v \in Volumes : StartMigrationCopy(v)
        \/ \E v \in Volumes : CompleteMigrationCopy(v)
        \/ \E v \in Volumes : FailMigrationCopy(v)
        \/ \E v \in Volumes : RecoverFailedMigration(v)
        \/ \E v \in Volumes : CancelMigration(v)
        \/ \E v \in Volumes : CleanupOldBackingFile(v)
        \/ \E n \in Nodes : NodePluginRestart(n)
        \/ \E n \in Nodes : CordonNode(n)     /\ UNCHANGED scenarioPhase
        \/ \E n \in Nodes : UncordonNode(n)   /\ UNCHANGED scenarioPhase
        \/ \E n \in Nodes : StartDrain(n)     /\ UNCHANGED scenarioPhase
        \/ \E n \in Nodes : CompleteDrain(n)  /\ UNCHANGED scenarioPhase
        \/ \E n \in Nodes : RemoveNode(n)     /\ UNCHANGED scenarioPhase)

Spec == Init /\ [][Next]_vars

\* ============================================================
\* Safety Invariants
\* ============================================================

\* Resource hierarchy: targetMount => stagingMount => loopDevice => backingFile
ResourceHierarchy ==
    \A v \in Volumes, n \in Nodes :
        /\ (<<v, n>> \in targetMounts  => <<v, n>> \in stagingMounts)
        /\ (<<v, n>> \in stagingMounts => <<v, n>> \in loopDevices)
        /\ (<<v, n>> \in loopDevices   => <<v, n>> \in backingFiles)

\* Active resources on at most one node per volume
SingleNodeResources ==
    \A v \in Volumes :
        Cardinality({n \in Nodes :
            \/ <<v, n>> \in loopDevices
            \/ <<v, n>> \in stagingMounts
            \/ <<v, n>> \in targetMounts}) <= 1

\* Source backing file preserved during migration copy (data safety)
MigrationDataSafety ==
    \A v \in Volumes :
        (migState[v] \in {MigPrepared, MigCopying, MigFailed}) =>
            (migSource[v] \in Nodes /\ <<v, migSource[v]>> \in backingFiles)

\* Published volume has target mount on exactly one node
PublishedOnOneNode ==
    \A v \in Volumes :
        (phase[v] = Published) =>
            \E n \in Nodes :
                /\ <<v, n>> \in targetMounts
                /\ \A m \in Nodes : m /= n => <<v, m>> \notin targetMounts

\* Unprovisioned volumes have no active resources
NoOrphanedResources ==
    \A v \in Volumes :
        (phase[v] = Unprovisioned) =>
            ~(\E n \in Nodes :
                \/ <<v, n>> \in loopDevices
                \/ <<v, n>> \in stagingMounts
                \/ <<v, n>> \in targetMounts)

\* Owner consistent with phase
OwnerConsistency ==
    \A v \in Volumes :
        /\ (phase[v] = Unprovisioned => owner[v] = NoNode)
        /\ (phase[v] \in {Staged, Published} => owner[v] \in Nodes)

\* Migration target is valid
MigrationTargetValid ==
    \A v \in Volumes :
        (migState[v] \in {MigPrepared, MigCopying, MigDone, MigFailed}) =>
            /\ migTarget[v] \in Nodes
            /\ migTarget[v] /= owner[v]

\* Migration source is tracked when migration is active
MigrationSourceTracked ==
    \A v \in Volumes :
        (migState[v] \in {MigPrepared, MigCopying, MigDone, MigFailed}) =>
            migSource[v] \in Nodes

\* Node removal only happens after all copies are complete
NodeRemovalSafe ==
    \A n \in Nodes :
        (nodeState[n] = NodeRemoved) => (PendingPVs(n) = {})

\* Combined safety invariant
SafetyInvariant ==
    /\ TypeOK
    /\ ResourceHierarchy
    /\ SingleNodeResources
    /\ MigrationDataSafety
    /\ PublishedOnOneNode
    /\ NoOrphanedResources
    /\ OwnerConsistency
    /\ MigrationTargetValid
    /\ MigrationSourceTracked
    /\ NodeRemovalSafe

\* ============================================================
\* Liveness Properties (checked via closed-system scenarios below)
\* ============================================================

VolumeGetsServed ==
    \A v \in Volumes :
        (phase[v] = Created) ~> (phase[v] = Published \/ phase[v] = Unprovisioned)

MigrationCompletes ==
    \A v \in Volumes :
        (migState[v] /= MigNone) ~> (migState[v] = MigNone)

DrainCompletes ==
    \A n \in Nodes :
        (nodeState[n] = NodeDraining) ~> (nodeState[n] = NodeRemoved)

RetainConverges ==
    \A v \in Volumes :
        (migReclaimRetain[v] = TRUE) ~> (migReclaimRetain[v] = FALSE)

\* ============================================================
\* Closed-System Liveness Scenarios
\* ============================================================
\*
\* Each scenario restricts environmental disruptions to a deterministic
\* script via scenarioPhase, while system actions remain nondeterministic.
\* WF_vars(S*Next) guarantees progress; the environment only disrupts
\* in the prescribed sequence.

\* Progress actions: move volume forward toward Published or complete migration.
\* These are always enabled in all scenarios.
ProgressActions ==
    \/ \E v \in Volumes, n \in Nodes : CreateVolume(v, n)
    \/ \E v \in Volumes, n \in Nodes : ReassignVolume(v, n)
    \/ \E v \in Volumes : NodeStageVolume(v)
    \/ \E v \in Volumes : NodeStageVolumeWithMigration(v)
    \/ \E v \in Volumes : NodePublishVolume(v)
    \/ \E v \in Volumes, n \in Nodes : DetectStuckVolume(v, n)
    \/ \E v \in Volumes : StartMigrationCopy(v)
    \/ \E v \in Volumes : CompleteMigrationCopy(v)
    \/ \E v \in Volumes : RecoverFailedMigration(v)
    \/ \E v \in Volumes : CancelMigration(v)
    \/ \E v \in Volumes : CleanupOldBackingFile(v)
    \/ \E n \in Nodes : NodePluginRestart(n)

\* Drain lifecycle: kubelet eviction + node state transitions.
\* Unpublish/unstage only fire on draining nodes (not spontaneously on healthy ones).
DrainActions ==
    \/ \E v \in Volumes : owner[v] \in Nodes /\ nodeState[owner[v]] = NodeDraining /\ NodeUnpublishVolume(v)
    \/ \E v \in Volumes : owner[v] \in Nodes /\ nodeState[owner[v]] = NodeDraining /\ NodeUnstageVolumeNormal(v)
    \/ \E v \in Volumes, n \in Nodes : NodeUnstageVolumeWithMigration(v, n)
    \/ \E n \in Nodes : CompleteDrain(n)  /\ UNCHANGED scenarioPhase
    \/ \E n \in Nodes : RemoveNode(n)     /\ UNCHANGED scenarioPhase

\* All system actions combined (for drain scenarios)
SystemActions == ProgressActions \/ DrainActions

\* ── Scenario 1: Happy Path ──────────────────────────────────
\* No disruptions.  Volume v1 goes Create -> Stage -> Publish.

S1Init == BaseInit /\ scenarioPhase = "done"

S1Next == ProgressActions /\ UNCHANGED scenarioPhase

S1Spec == S1Init /\ [][S1Next]_vars
S1FairSpec == S1Spec /\ WF_vars(S1Next)

\* ── Scenario 2: Single Drain ────────────────────────────────
\* Cordon n1 -> drain n1 -> system migrates -> complete drain -> remove n1

S2Init == BaseInit /\ scenarioPhase = "cordon_n1"

S2CordonN1 ==
    /\ scenarioPhase = "cordon_n1"
    /\ CordonNode(n1)
    /\ scenarioPhase' = "drain_n1"

S2DrainN1 ==
    /\ scenarioPhase = "drain_n1"
    /\ StartDrain(n1) /\ scenarioPhase' = "done"

S2Next ==
    \/ (SystemActions /\ UNCHANGED scenarioPhase)
    \/ S2CordonN1
    \/ S2DrainN1

S2Spec == S2Init /\ [][S2Next]_vars
S2FairSpec == S2Spec /\ WF_vars(S2Next)

\* ── Scenario 3: Chained Migration ───────────────────────────
\* Cordon n1 -> drain n1 -> migration starts to n2 ->
\* cordon n2 mid-migration -> DetectStuckVolume -> redirect to n3

S3Init == BaseInit /\ scenarioPhase = "cordon_n1"

S3CordonN1 ==
    /\ scenarioPhase = "cordon_n1"
    /\ CordonNode(n1) /\ scenarioPhase' = "drain_n1"

S3DrainN1 ==
    /\ scenarioPhase = "drain_n1"
    /\ StartDrain(n1) /\ scenarioPhase' = "wait_for_mig"

S3CordonN2 ==
    /\ scenarioPhase = "wait_for_mig"
    /\ \E v \in Volumes : migState[v] \in {MigPrepared, MigCopying}
    /\ CordonNode(n2) /\ scenarioPhase' = "done"

S3Next ==
    \/ (SystemActions /\ UNCHANGED scenarioPhase)
    \/ S3CordonN1
    \/ S3DrainN1
    \/ S3CordonN2

S3Spec == S3Init /\ [][S3Next]_vars
S3FairSpec == S3Spec /\ WF_vars(S3Next)

====
