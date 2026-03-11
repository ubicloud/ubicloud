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
