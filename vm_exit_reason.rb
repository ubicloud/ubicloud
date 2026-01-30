# frozen_string_literal: true

# Sketch: VM exit reason detection for Metal::Nexus
#
# This module provides vm_exit_reason and a replacement unavailable
# label that uses it. Intended to be integrated into
# Prog::Vm::Metal::Nexus.
#
# ## Experimental results (2026-01-30)
#
# Tested on Ubuntu 24.04 with cloud-hypervisor v50, using a
# persistent systemd unit with ExecStop=ch-remote shutdown-vmm
# (matching production). Key finding: when the CH main process
# exits on its own, systemd runs ExecStop, which fails because
# the API socket is already gone. This makes Result="exit-code"
# the common case for all self-exits, not Result="success".
#
#   | Cause              | systemd Result | Journal grep match         |
#   |--------------------|----------------|----------------------------|
#   | Guest ACPI shutdown| exit-code      | "ACPI Shutdown signalled"  |
#   | SIGTERM (direct)   | exit-code      | (no match)                 |
#   | SIGKILL / OOM      | signal         | (no CH log output)         |
#   | systemctl stop     | success        | (ExecStop ran cleanly)     |
#
# The original sketch assumed Result="success" was the ambiguous
# case needing journal disambiguation. In practice, "exit-code"
# is the ambiguous one. "signal" is unambiguous (forcible kill).
# "success" means ExecStop worked (orderly operator-initiated
# shutdown via ch-remote).
#
# To reproduce these results, see companion script:
#   test_vm_exit_reason.rb

module VmExitReason
  # Unambiguous systemd Result values that need no journal check.
  # These indicate the process was forcibly terminated (not a
  # clean exit), so we always page.
  FORCIBLE_RESULTS = %w[signal core-dump oom-kill timeout].freeze

  # Queries systemd and (for the ambiguous exit-code case) CH's
  # own journald output to classify why the VM unit stopped.
  #
  # systemd's Result property reflects how the unit ended:
  #
  #   "success"    — ExecStop ran and succeeded. In production
  #                  this means ch-remote shutdown-vmm worked,
  #                  i.e. an operator or automation stopped the
  #                  VM intentionally.
  #
  #   "exit-code"  — The main process exited on its own (any
  #                  exit code) AND ExecStop failed (because the
  #                  CH socket was already gone). This is the
  #                  ambiguous case: could be guest ACPI shutdown,
  #                  SIGTERM caught by CH, or any other clean exit.
  #
  #   "signal"     — Process killed by signal (SIGKILL, OOM, etc.)
  #   "core-dump"  — Process dumped core.
  #   "oom-kill"   — Killed by OOM.
  #   "timeout"    — ExecStop timed out.
  #
  # For "exit-code" we check CH's journal output to disambiguate.
  # Cloud-hypervisor logs a distinctive line before each exit path.
  # The grep uses -m1 (first match) and -F (fixed strings). The
  # match strings come from CH source (stable across shipped
  # versions). To find them:
  #
  #   grep -n 'exit_evt.write' vmm/src/**/*.rs devices/src/**/*.rs
  #
  # and check the log line before each call site. As of v50:
  #
  #   "ACPI Shutdown signalled"  — devices/src/acpi.rs  (guest S5)
  #   "vCPU thread panicked"     — vmm/src/cpu.rs       (catch_unwind)
  #   "VCPU generated error"     — vmm/src/cpu.rs       (hypervisor err)
  #   "thread panicked"          — vmm/src/lib.rs et al (any thread)
  #
  def vm_exit_reason
    result, invocation_id = host.sshable.cmd(
      "systemctl show -p Result -p InvocationID --value :vm_name", vm_name:
    ).strip.split("\n")

    # Orderly shutdown via ch-remote (operator/automation).
    return {result:, reason: "operator-stop"} if result == "success"

    # Forcible kill — no CH logs to check, always page-worthy.
    return {result:, reason: result} if FORCIBLE_RESULTS.include?(result)

    # "exit-code" (or any other unexpected value): CH exited on
    # its own. Check journal to find out why.
    reason = begin
      host.sshable.cmd(
        "journalctl _SYSTEMD_INVOCATION_ID=:invocation_id " \
        "-o cat -n 50 --no-pager " \
        "| grep -m1 -oF " \
        "-e 'ACPI Shutdown signalled' " \
        "-e 'vCPU thread panicked' " \
        "-e 'VCPU generated error' " \
        "-e 'thread panicked'",
        vm_name:, invocation_id:
      ).strip
    rescue Sshable::SshError
      # grep exit code 1 (no match) raises SshError.
      nil
    end

    {result:, reason: reason || "clean-exit-unknown-cause"}
  end

  # Replacement for the unavailable label in Prog::Vm::Metal::Nexus.
  # Uses vm_exit_reason to decide whether to page or accept the stop.
  #
  # label def unavailable
  #   when_start_after_host_reboot_set? do
  #     incr_checkup
  #     hop_start_after_host_reboot
  #   end
  #
  #   begin
  #     if available?
  #       decr_checkup
  #       Page.from_tag_parts("VmExit", vm.ubid)&.incr_resolve
  #       hop_wait
  #     else
  #       exit_info = vm_exit_reason
  #
  #       case exit_info[:reason]
  #       when "ACPI Shutdown signalled"
  #         # Guest initiated shutdown (customer action). Log it,
  #         # don't page, stop polling.
  #         Clog.emit("VM stopped by guest ACPI shutdown",
  #           {vm_exit: {vm: vm.ubid, **exit_info}})
  #         decr_checkup
  #         # Transition to stopped so the strand doesn't keep
  #         # polling. The customer can use the "start" action to
  #         # bring the VM back up.
  #         incr_stop
  #         hop_stopped
  #       when "operator-stop"
  #         # ExecStop succeeded — someone ran systemctl stop or
  #         # ch-remote shutdown-vmm. This is intentional; don't
  #         # page.
  #         Clog.emit("VM stopped by operator",
  #           {vm_exit: {vm: vm.ubid, **exit_info}})
  #         decr_checkup
  #         incr_stop
  #         hop_stopped
  #       else
  #         # Unexpected exit: signal, crash, unknown cause.
  #         # Page with the reason in the summary.
  #         Prog::PageNexus.assemble(
  #           "#{vm.ubid} stopped unexpectedly (#{exit_info[:reason]})",
  #           ["VmExit", vm.ubid], vm.ubid,
  #           extra_data: {vm_host: host.ubid, **exit_info}
  #         )
  #       end
  #     end
  #   rescue Sshable::SshError
  #     # Host unreachable — will be handled by HostNexus.
  #   end
  #
  #   nap 30
  # end
end
