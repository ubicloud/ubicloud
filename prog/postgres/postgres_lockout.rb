# frozen_string_literal: true

require "google/cloud/compute/v1"
require "googleauth"

class Prog::Postgres::PostgresLockout < Prog::Base
  include GcpLro

  GCP_BUDGET = 30
  GCP_ERRORS = [
    Google::Cloud::Error, Google::Auth::CredentialsError,
    Signet::AuthorizationError, Signet::ParseError, Signet::UnexpectedStatusError,
  ].freeze

  subject_is :postgres_server
  frame_reader :mechanism
  frame_accessor :gcp_deadline

  def before_run
    super
    pop_gcp_failed("deadline passed") if gcp_deadline && Time.now.to_i > gcp_deadline
  end

  label def start
    if mechanism == "stop_vm"
      self.gcp_deadline = Time.now.to_i + GCP_BUDGET
      hop_stop_vm
    end

    send("lockout_with_#{mechanism}")
    pop_succeeded
  rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError, Aws::EC2::Errors::ServiceError
    pop "lockout_failed"
  end

  label def stop_vm
    op = credential.lockout_compute_client.stop(
      project: gcp_project_id,
      zone: gcp_zone,
      instance: vm.name,
      discard_local_ssd: true,
      request_id: strand.id,
    )
    save_gcp_op("stop_vm", op_name: op.name, scope: "zone", scope_value: gcp_zone)
    hop_wait_stop_vm
  rescue Google::Cloud::NotFoundError
    pop_succeeded
  rescue *GCP_ERRORS => e
    pop_gcp_failed(e.message, e.class.name)
  end

  label def wait_stop_vm
    op = poll_gcp_op("stop_vm", client: credential.lockout_zone_operations_client)
    nap 1 unless op.status == :DONE
    pop_gcp_failed(op_error_message(op)) if op_error?(op)
    pop_succeeded
  rescue *GCP_ERRORS => e
    pop_gcp_failed(e.message, e.class.name)
  end

  def lockout_with_pg_stop
    postgres_server.vm.sshable.cmd(
      "timeout 10 sudo pg_ctlcluster :version main stop -m immediate",
      version: postgres_server.version,
      timeout: 15,
    )
  end

  def lockout_with_hba
    postgres_server.vm.sshable.cmd(
      "timeout 10 sudo postgres/bin/lockout-hba :version",
      version: postgres_server.version,
      timeout: 15,
    )
  end

  def lockout_with_host_routing
    postgres_server.vm.vm_host.sshable.cmd(
      "timeout 10 sudo ip link set :interface down", interface: "vetho#{postgres_server.vm.inhost_name}",
      timeout: 15,
    )
  end

  def lockout_with_detach_nic
    client = postgres_server.vm.location.location_credential_aws.client
    network_interface = client.describe_network_interfaces(
      network_interface_ids: [postgres_server.vm.user_nic.nic_aws_resource.network_interface_id],
    ).network_interfaces.first
    client.detach_network_interface(
      attachment_id: network_interface.attachment.attachment_id,
      force: true,
    )
  end

  private

  def pop_succeeded
    Clog.emit("Fenced unresponsive primary", {fenced_unresponsive_primary: {server_ubid: postgres_server.ubid, mechanism:}})
    pop "lockout_succeeded"
  end

  def pop_gcp_failed(error, error_class = nil)
    Clog.emit("GCP lockout failed", {gcp_lockout_failed: {server_ubid: postgres_server.ubid, mechanism:, error:, error_class:}})
    pop "lockout_failed"
  end

  def vm
    @vm ||= postgres_server.vm
  end

  def credential
    @credential ||= vm.location.location_credential_gcp
  end

  def gcp_project_id
    credential.project_id
  end

  def gcp_zone
    @gcp_zone ||= "#{vm.location.name.delete_prefix("gcp-")}-#{vm.vm_gcp_resource.location_az.az}"
  end
end
