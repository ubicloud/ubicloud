# frozen_string_literal: true

require "aws-sdk-ec2"
require "google/cloud/compute/v1"

class Prog::Vm::RunCommandNexus < Prog::Base
  subject_is :run_command

  # Not customer-controllable: callers must pass one of these fixed
  # strings, never data derived from a request body.
  COMMANDS = ["fetch_serial_log"].freeze

  MAX_ATTEMPTS = 3
  RETRY_NAP_SECONDS = 15
  RETRYABLE_ERRORS = [Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS, Aws::EC2::Errors::ServiceError, Google::Cloud::Error].freeze

  frame_accessor :attempts

  def self.assemble(vm_id:, command:)
    fail "Unknown run command: #{command}" unless COMMANDS.include?(command)
    vm = Vm[vm_id]
    fail "Vm does not exist" unless vm

    # Fail synchronously instead of storing an opaque "failed" RunCommand
    # the caller has to poll for, since this is a static VM configuration
    # issue that a retry would never resolve.
    if command == "fetch_serial_log" && vm.location.provider_dispatcher_group_name == "metal" && !vm.vm_host
      fail CloverError.new(400, "InvalidRequest", "VM has no assigned host")
    end

    DB.transaction do
      # At most one active run per (vm, command); reuse the row across
      # runs instead of archiving every fetch's output, since consecutive
      # fetches will mostly be identical. A root Strand self-reaps on
      # exit, so run_command.strand existing means a previous run is
      # still genuinely in flight - leave its lease alone rather than
      # pulling the strand out from under it, since callers already
      # avoid requesting a new run while status is "created".
      rc = RunCommand.find_or_create(vm_id:, command:)
      next rc.strand if rc.strand
      rc.update(status: "created", output: nil, run_at: nil, created_at: Time.now)
      Strand.create_with_id(rc, prog: "Vm::RunCommandNexus", label: "start")
    end
  end

  def vm
    @vm ||= run_command.vm
  end

  label def start
    output = send(run_command.command)
    run_command.update(status: "succeeded", output:, run_at: Time.now)
    pop "run command succeeded"
  rescue *RETRYABLE_ERRORS => ex
    self.attempts = (attempts || 0) + 1
    if attempts < MAX_ATTEMPTS
      Clog.emit("run command failed, retrying", {run_command_retry: Util.exception_to_hash(ex, into: {attempt: attempts})})
      nap RETRY_NAP_SECONDS
    else
      Clog.emit("run command failed", {run_command_failure: Util.exception_to_hash(ex)})
      # Don't expose internal exception messages to the user.
      run_command.update(status: "failed", output: nil, run_at: Time.now)
      pop "run command failed"
    end
  end

  private

  def fetch_serial_log
    vm.fetch_serial_log
  end
end
