# frozen_string_literal: true

class Prog::Postgres::PostgresLockout < Prog::Base
  subject_is :postgres_server

  label def start
    mechanism = strand.stack.first["mechanism"]

    begin
      send("lockout_with_#{mechanism}")
      Clog.emit("Fenced unresponsive primary", {fenced_unresponsive_primary: {server_ubid: postgres_server.ubid, mechanism:}})
      pop "lockout_succeeded"
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError, Aws::EC2::Errors::ServiceError
      pop "lockout_failed"
    end
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
    nar = postgres_server.vm.nic.nic_aws_resource
    client = postgres_server.vm.location.location_credential_aws.client
    network_interface = client.describe_network_interfaces(
      network_interface_ids: [nar.network_interface_id],
    ).network_interfaces.first
    client.detach_network_interface(
      attachment_id: network_interface.attachment.attachment_id,
      force: true,
    )
  end
end
