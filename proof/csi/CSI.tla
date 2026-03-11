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
       /\ loopDevices'   = loopDevices   \cup {<<v, newNode>>}
       /\ stagingMounts' = stagingMounts \cup {<<v, newNode>>}
       /\ migState'      = [migState  EXCEPT ![v] = MigNone]
       /\ migTarget'     = [migTarget EXCEPT ![v] = NoNode]
       /\ migSource'     = [migSource EXCEPT ![v] = NoNode]
       /\ migRetryCount' = [migRetryCount EXCEPT ![v] = 0]
       /\ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = FALSE]
       /\ paged'         = [paged EXCEPT ![v] = FALSE]
       /\ UNCHANGED <<backingFiles, targetMounts, nodeSchedulable, nodeState>>
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
       /\ backingFiles'  = backingFiles  \cup {<<v, n>>}
       /\ loopDevices'   = loopDevices   \cup {<<v, n>>}
       /\ stagingMounts' = stagingMounts \cup {<<v, n>>}
       /\ UNCHANGED <<owner, targetMounts, nodeSchedulable, nodeState,
                      migState, migTarget, migSource, migRetryCount,
                      migReclaimRetain, paged>>
\* CompleteMigrationCopy: daemonizer2 "Succeeded" → backingFiles' \union= {<<v, newNode>>}
CompleteMigrationCopy(v) ==
    /\ migState[v] = MigCopying
    /\ migTarget[v] \in Nodes
    /\ migSource[v] \in Nodes
    /\ <<v, migSource[v]>> \in backingFiles
    /\ LET newNode == migTarget[v] IN
       /\ backingFiles' = backingFiles \cup {<<v, newNode>>}
       /\ migState'     = [migState EXCEPT ![v] = MigDone]
       /\ UNCHANGED <<phase, owner, loopDevices, stagingMounts, targetMounts,
                      nodeSchedulable, nodeState, migTarget, migSource,
                      migRetryCount, migReclaimRetain, paged>>
\* StartMigrationCopy: daemonizer2 "NotStarted" → run rsync
StartMigrationCopy(v) ==
    /\ migState[v] = MigPrepared
    /\ migTarget[v] \in Nodes
    /\ migSource[v] \in Nodes
    /\ <<v, migSource[v]>> \in backingFiles    \* source data must exist
    /\ migState' = [migState EXCEPT ![v] = MigCopying]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migTarget,
                   migSource, migRetryCount, migReclaimRetain, paged>>
\* ExhaustMigrationRetries: retry_count ≥ MAX → MigStuck (hard error)
ExhaustMigrationRetries(v) ==
    /\ migState[v] = MigCopying
    /\ migTarget[v] \in Nodes
    /\ migRetryCount[v] >= MaxRetries
    /\ migState' = [migState EXCEPT ![v] = MigStuck]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migTarget,
                   migSource, migRetryCount, migReclaimRetain, paged>>
\* FailMigrationCopy: retry_count < MAX → increment + CopyNotFinishedError
FailMigrationCopy(v) ==
    /\ migState[v] = MigCopying
    /\ migTarget[v] \in Nodes
    /\ migRetryCount[v] < MaxRetries
    /\ migState'      = [migState EXCEPT ![v] = MigFailed]
    /\ migRetryCount' = [migRetryCount EXCEPT ![v] = migRetryCount[v] + 1]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migTarget,
                   migSource, migReclaimRetain, paged>>
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
                      migSource, migRetryCount, migReclaimRetain, paged>>
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
                      nodeState, migRetryCount, paged>>
\* Models NodeService#node_publish_volume: bind mount from staging to target.
NodePublishVolume(v) ==
    /\ phase[v] = Staged
    /\ owner[v] \in Nodes
    /\ LET n == owner[v] IN
       /\ <<v, n>> \in stagingMounts
       /\ phase'        = [phase EXCEPT ![v] = Published]
       /\ targetMounts' = targetMounts \cup {<<v, n>>}
       /\ UNCHANGED <<owner, backingFiles, loopDevices, stagingMounts,
                      nodeSchedulable, nodeState, migState, migTarget,
                      migSource, migRetryCount, migReclaimRetain, paged>>
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
                      migSource, migRetryCount, migReclaimRetain, paged>>
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
                   migSource, migRetryCount, migReclaimRetain, paged>>

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
                   migSource, migRetryCount, migReclaimRetain, paged>>
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
                   migSource, migRetryCount, migReclaimRetain, paged>>
\* PendingPVs(n) = {} → hop_remove_node_from_cluster
\* Models check_pulse paging: KubernetesCluster#check_pulse detects
\* stuck_pvs (retry count >= 3) and creates a Page.
PageStuckMigration(v) ==
    /\ migState[v] = MigStuck
    /\ paged[v] = FALSE
    /\ paged' = [paged EXCEPT ![v] = TRUE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migState,
                   migTarget, migSource, migRetryCount, migReclaimRetain>>
\* migState[v] = MigStuck ≡ retry_count ≥ MAX_MIGRATION_RETRIES
\* paged' = TRUE → Prog::PageNexus.assemble
\* ResolveStuckMigration: paged' = FALSE (see spec.tla)
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
                   migRetryCount, migReclaimRetain, paged>>

\* Models ControllerService#delete_volume: SSHes to the node hosting the
\* backing file and deletes it.  The volume returns to Unprovisioned.
\* NOTE: code has no migration guard — spec is stricter (intentional).
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
                      migSource, migRetryCount, migReclaimRetain, paged>>

\* ============================================================
\* Cordon / Uncordon (out-of-line: implicit in kubectl drain)
\* ============================================================

\* Models KubernetesNodeNexus#retire -> drain: cordon + kubectl drain.
CordonNode(n) ==
    /\ n \in Nodes
    /\ nodeSchedulable[n] = TRUE
    /\ nodeSchedulable' = [nodeSchedulable EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeState, migState, migTarget, migSource,
                   migRetryCount, migReclaimRetain, paged>>

UncordonNode(n) ==
    /\ n \in Nodes
    /\ nodeSchedulable[n] = FALSE
    /\ nodeSchedulable' = [nodeSchedulable EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeState, migState, migTarget, migSource,
                   migRetryCount, migReclaimRetain, paged>>

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
\* Effect: roll intermediate PV to Delete, reset retry count,
\* recreate PVC targeting a new schedulable node.
\* migSource preserved (trim_pvc uses ||= to keep original source PV).
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
    /\ migRetryCount' = [migRetryCount EXCEPT ![v] = 0]
    /\ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = TRUE]
    /\ paged'         = [paged EXCEPT ![v] = FALSE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migSource>>

\* ============================================================
\* Recovery (out-of-line: bundled with fail in code)
\* ============================================================

\* Recovery from failed copy (within retry budget):
\* clean daemonizer2 unit -> CopyNotFinishedError -> kubelet retries
\* NodeStageVolume -> migrate_pvc_data sees "NotStarted" again.
RecoverFailedMigration(v) ==
    /\ migState[v] = MigFailed
    /\ migTarget[v] \in Nodes
    /\ migState' = [migState EXCEPT ![v] = MigPrepared]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migTarget,
                   migSource, migRetryCount, migReclaimRetain, paged>>

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
                   migSource, migRetryCount, migReclaimRetain, paged>>

\* ============================================================
\* Page Resolution (NEW — easy proof fix)
\* ============================================================

\* Models KubernetesCluster#check_pulse resolving a page when stuck_pvs is empty.
\* Code: Page.from_tag_parts("KubernetesClusterPVMigrationStuck", id)&.incr_resolve
ResolveStuckMigration(v) ==
    /\ paged[v] = TRUE
    /\ migState[v] = MigNone
    /\ paged' = [paged EXCEPT ![v] = FALSE]
    /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
                   targetMounts, nodeSchedulable, nodeState, migState,
                   migTarget, migSource, migRetryCount, migReclaimRetain>>

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
\* Next-State Relation
\* ============================================================

Next ==
    \/ \E v \in Volumes, n \in Nodes : CreateVolume(v, n)
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
    \/ \E v \in Volumes : ExhaustMigrationRetries(v)
    \/ \E v \in Volumes : PageStuckMigration(v)
    \/ \E v \in Volumes : ResolveStuckMigration(v)
    \/ \E v \in Volumes : RecoverFailedMigration(v)
    \/ \E v \in Volumes : CleanupOldBackingFile(v)
    \/ \E n \in Nodes : NodePluginRestart(n)
    \/ \E n \in Nodes : CordonNode(n)
    \/ \E n \in Nodes : UncordonNode(n)
    \/ \E n \in Nodes : StartDrain(n)
    \/ \E n \in Nodes : CompleteDrain(n)
    \/ \E n \in Nodes : RemoveNode(n)

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Next)

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
        (migState[v] \in {MigPrepared, MigCopying, MigFailed, MigStuck}) =>
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
        (migState[v] \in {MigPrepared, MigCopying, MigDone, MigFailed, MigStuck}) =>
            /\ migTarget[v] \in Nodes
            /\ migTarget[v] /= owner[v]

\* Migration source is tracked when migration is active
MigrationSourceTracked ==
    \A v \in Volumes :
        (migState[v] \in {MigPrepared, MigCopying, MigDone, MigFailed, MigStuck}) =>
            migSource[v] \in Nodes

\* Retry count never exceeds MaxRetries
RetryCountBounded ==
    \A v \in Volumes :
        migRetryCount[v] <= MaxRetries

\* Stuck volumes are always paged eventually (checked via liveness, not invariant)
\* But we can check: a stuck volume must have exhausted retries.
StuckImpliesExhausted ==
    \A v \in Volumes :
        (migState[v] = MigStuck) => (migRetryCount[v] >= MaxRetries)

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
    /\ RetryCountBounded
    /\ StuckImpliesExhausted
    /\ NodeRemovalSafe

\* ============================================================
\* Liveness (checked under FairSpec)
\* ============================================================

\* Every published volume can eventually return to Unprovisioned.
Liveness ==
    \A v \in Volumes :
        (phase[v] = Published) ~> (phase[v] = Unprovisioned)

\* Every stuck volume eventually gets paged (operator notified).
StuckGetsPaged ==
    \A v \in Volumes :
        (migState[v] = MigStuck) ~> (paged[v] = TRUE)

====
