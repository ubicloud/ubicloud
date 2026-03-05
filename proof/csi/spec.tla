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
