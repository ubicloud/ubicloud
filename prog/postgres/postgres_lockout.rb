# frozen_string_literal: true

class Prog::Postgres::PostgresLockout < Prog::Base
  subject_is :postgres_server
  frame_reader :mechanism

  label def start
    send("lockout_with_#{mechanism}")
    Clog.emit("Fenced unresponsive primary", {fenced_unresponsive_primary: {server_ubid: postgres_server.ubid, mechanism:}})
    pop "lockout_succeeded"
  rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError, Aws::EC2::Errors::ServiceError, Google::Cloud::Error
    pop "lockout_failed"
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
    attachment = client.describe_network_interfaces(
      network_interface_ids: [postgres_server.vm.user_nic.nic_aws_resource.network_interface_id],
    ).network_interfaces.first.attachment
    return if attachment.nil? || %w[detaching detached].include?(attachment.status)

    client.detach_network_interface(attachment_id: attachment.attachment_id, force: true)
  end

  def lockout_with_delete_nic
    vm = postgres_server.vm
    credential = vm.location.location_credential_gcp
    client = credential.lockout_compute_client
    request = {project: credential.project_id, zone: "#{vm.location.name.delete_prefix("gcp-")}-#{vm.vm_gcp_resource.location_az.az}", instance: vm.name}
    nic_name = "nic0.#{GcpDualNicNetplan::VLAN}"
    return if client.get(**request).network_interfaces.none? { it.name == nic_name }

    client.delete_network_interface(**request, network_interface_name: nic_name, request_id: strand.id)
  end
end
