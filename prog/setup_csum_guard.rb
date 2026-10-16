# frozen_string_literal: true

# Install or uninstall the checksum guard, and record the outcome in
# vm_host.csum_guard_enabled.
#
# Runs in the host's strand, so failures page rather than raise: a
# retried failure would block the host's other work.
class Prog::SetupCsumGuard < Prog::Base
  subject_is :sshable, :vm_host
  frame_reader :enable

  label def start
    register_deadline(nil, 10 * 60)
    action = enable ? "install" : "uninstall"

    begin
      sshable.cmd("sudo host/bin/setup-csum-guard :action", action:)
    rescue Sshable::SshError => ex
      Prog::PageNexus.assemble("#{vm_host.ubid} could not #{action} the checksum guard",
        ["CsumGuardFailed", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id,
        extra_data: {"stderr" => ex.stderr.to_s[-2000..] || ex.stderr.to_s})
      pop "csum guard #{action} failed"
    end

    vm_host.update(csum_guard_enabled: enable)
    Page.from_tag_parts("CsumGuardFailed", vm_host.ubid)&.incr_resolve
    pop(enable ? "csum guard installed" : "csum guard uninstalled")
  end
end
