# frozen_string_literal: true

class Prog::Vm::HostCleanup < Prog::Base
  subject_is :vm_host, :sshable

  # inhost signatures for slice units that belong to this fabric. See
  # StaleVmCleaner::SLICE_NAME_RE in rhizome.
  SLICE_UNIT_RE = /\A[a-z0-9]+_vm[0-9a-hj-km-np-tv-z]{6}\.slice\z/

  # Reconciles the host's on-disk VM/slice artifacts against the control
  # plane's expected live set. Leftover artifacts (from VMs destroyed while the
  # host was draining/unreachable, so the host-side purge never ran) are purged
  # idempotently.
  def self.assemble(vm_host_id)
    Strand.create(prog: "Vm::HostCleanup", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  def expected_vm_names
    vm_host.vms.map(&:inhost_name)
  end

  def expected_slice_names
    vm_host.slices
      .map(&:inhost_name)
      .select { |name| name.match?(SLICE_UNIT_RE) }
  end

  label def start
    # Only clean a host that is accepting allocations; while draining, its VMs
    # are still expected to exist and unreachability is common. Re-run is
    # triggered by the accepting transition (host_nexus start_vms / admin).
    hop_wait unless vm_host.allocation_state == "accepting"

    result = begin
      JSON.parse(sshable.cmd(
        "sudo host/bin/cleanup-stale-vms",
        stdin: JSON.generate({expected_vms: expected_vm_names, expected_slices: expected_slice_names}),
        log: :on_error,
      ))
    rescue Sshable::SshTimeout, *Sshable::SSH_CONNECTION_ERRORS => ex
      # Host just came back up; it may not be fully reachable yet. Log and let
      # a later accepting-transition re-run it.
      Clog.emit("VM host stale artifact cleanup failed", {
        vm_host_stale_cleanup_failed: Util.exception_to_hash(ex, into: {vm_host: vm_host.ubid}),
      })
      nap 5 * 60
    end

    if (result["vms"] || result["slices"]).any?
      Clog.emit("VM host stale artifacts cleaned", {
        vm_host_stale_cleanup: {vm_host: vm_host.ubid, vms: result["vms"] || [], slices: result["slices"] || []},
      })
    end

    pop "stale vms cleaned"
  end

  label def wait
    nap 5 * 60
  end
end
