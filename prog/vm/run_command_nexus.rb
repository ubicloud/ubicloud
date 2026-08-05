# frozen_string_literal: true

require "base64"

class Prog::Vm::RunCommandNexus < Prog::Base
  subject_is :run_command

  # Not customer-controllable: callers must pass one of these fixed
  # strings, never data derived from a request body.
  COMMANDS = ["fetch_serial_log"].freeze

  def self.assemble(vm_id:, command:)
    fail "Unknown run command: #{command}" unless COMMANDS.include?(command)
    fail "Vm does not exist" unless Vm[vm_id]

    DB.transaction do
      rc = RunCommand.create(vm_id:, command:)
      Strand.create_with_id(rc, prog: "Vm::RunCommandNexus", label: "start")
    end
  end

  def vm
    @vm ||= run_command.vm
  end

  label def start
    output = case run_command.command
    when "fetch_serial_log"
      fetch_serial_log
    else
      # Unreachable: #assemble already validates against COMMANDS.
      fail "Unknown run command: #{run_command.command}"
    end

    run_command.update(status: "succeeded", output:, run_at: Time.now)
    pop "run command succeeded"
  rescue => ex
    Clog.emit("run command failed", Util.exception_to_hash(ex))
    run_command.update(status: "failed", output: ex.message, run_at: Time.now)
    pop "run command failed"
  end

  private

  def fetch_serial_log
    case vm.location.provider_dispatcher_group_name
    when "metal"
      fail "VM has no assigned host" unless (host = vm.vm_host)
      host.sshable.cmd("sudo tail -c :max_bytes /vm/:vm_name/serial.log", max_bytes: RunCommand::MAX_OUTPUT_BYTES, vm_name: vm.inhost_name)
    when "aws"
      response = vm.location.location_credential_aws.client.get_console_output(instance_id: vm.aws_instance.instance_id)
      tail_bytes(response.output ? Base64.decode64(response.output) : "")
    when "gcp"
      credential = vm.location.location_credential_gcp
      zone = "#{vm.location.name.delete_prefix("gcp-")}-#{vm.vm_gcp_resource.location_az.az}"
      response = credential.compute_client.get_serial_port_output(project: credential.project_id, zone:, instance: vm.name)
      tail_bytes(response.contents || "")
    else
      # Unreachable: Location#provider_dispatcher_group_name only returns
      # one of the values handled above.
      fail "Unsupported provider for serial console log: #{vm.location.provider_dispatcher_group_name}"
    end
  end

  def tail_bytes(s)
    (s.bytesize > RunCommand::MAX_OUTPUT_BYTES) ? s.byteslice(-RunCommand::MAX_OUTPUT_BYTES..) : s
  end
end
