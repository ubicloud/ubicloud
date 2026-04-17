# frozen_string_literal: true

require "aws-sdk-ec2"

# :nocov:
class Prog::Postgres::PostgresServerAwsNicMigration < Prog::Base
  subject_is :postgres_server

  MIGRATION_DEADLINE_SECONDS = 48 * 60 * 60
  DRAIN_POLL_INTERVAL_SECONDS = 60

  label def start
    register_deadline(nil, MIGRATION_DEADLINE_SECONDS)
    nic = postgres_server.vm.nic
    nar = nic.nic_aws_resource
    fail "PostgresServer #{postgres_server.ubid} is not on AWS" unless postgres_server.aws?

    instance_enis = client.describe_instances(
      instance_ids: [postgres_server.vm.aws_instance.instance_id],
    ).reservations.first.instances.first.network_interfaces
    fail "PostgresServer #{postgres_server.ubid} already has more than one attached ENI" if instance_enis.length > 1

    update_stack({
      "old_network_interface_id" => nar.network_interface_id,
      "old_eip_allocation_id" => nar.eip_allocation_id,
      "old_private_ipv4" => nic.private_ipv4.to_s,
      "old_public_ipv4" => postgres_server.vm.sshable.host,
    })
    hop_create_new_nic
  end

  label def create_new_nic
    if frame["new_network_interface_id"].nil?
      response = client.create_network_interface(
        subnet_id: nic.nic_aws_resource.subnet_id,
        ipv_6_prefix_count: 1,
        groups: [nic.private_subnet.private_subnet_aws_resource.security_group_id],
        tag_specifications: Util.aws_tag_specifications("network-interface", "#{nic.name}-mig"),
        client_token: "#{strand.id}-nic",
      )
      update_stack({"new_network_interface_id" => response.network_interface.network_interface_id})
    end
    hop_wait_new_nic_created
  end

  label def wait_new_nic_created
    new_nic = client.describe_network_interfaces(
      network_interface_ids: [frame["new_network_interface_id"]],
    ).network_interfaces.first
    nap 1 unless new_nic&.status == "available"

    update_stack({"new_private_ipv4" => new_nic.private_ip_address})
    hop_attach_new_nic
  end

  label def attach_new_nic
    if frame["new_attachment_id"].nil?
      response = client.attach_network_interface(
        network_interface_id: frame["new_network_interface_id"],
        instance_id: postgres_server.vm.aws_instance.instance_id,
        device_index: 1,
      )
      update_stack({"new_attachment_id" => response.attachment_id})
    end
    hop_allocate_new_eip
  end

  label def allocate_new_eip
    if frame["new_eip_allocation_id"].nil?
      response = client.allocate_address(
        tag_specifications: Util.aws_tag_specifications("elastic-ip", "#{nic.name}-mig"),
      )
      update_stack({"new_eip_allocation_id" => response.allocation_id})
    end
    hop_associate_new_eip
  end

  label def associate_new_eip
    address = client.describe_addresses(
      filters: [{name: "allocation-id", values: [frame["new_eip_allocation_id"]]}],
    ).addresses.first

    unless address&.network_interface_id
      client.associate_address(
        allocation_id: frame["new_eip_allocation_id"],
        network_interface_id: frame["new_network_interface_id"],
      )
      address = client.describe_addresses(
        filters: [{name: "allocation-id", values: [frame["new_eip_allocation_id"]]}],
      ).addresses.first
    end

    update_stack({"new_public_ipv4" => address.public_ip})
    hop_wait_guest_sees_eth1
  end

  label def wait_guest_sees_eth1
    postgres_server.vm.sshable.cmd("ip -br addr show eth1 | grep -q UP")
    hop_flip_hosts_file
  rescue Sshable::SshError
    nap 2
  end

  label def flip_hosts_file
    DB.transaction do
      nic.update(private_ipv4: "#{frame["new_private_ipv4"]}/32")
      AssignedVmAddress.where(dst_vm_id: postgres_server.vm.id).update(ip: "#{frame["new_public_ipv4"]}/32")
    end
    resource.servers.each(&:incr_configure)
    hop_wait_configure_propagated
  end

  label def wait_configure_propagated
    nap 5 if resource.servers.any?(&:configure_set?)
    hop_update_dns_record
  end

  label def update_dns_record
    resource.incr_refresh_dns_record
    hop_wait_dns_propagated
  end

  label def wait_dns_propagated
    unless frame["dns_propagation_waited"]
      update_stack({"dns_propagation_waited" => true})
      nap 60
    end
    hop_wait_old_connections_drain
  end

  label def wait_old_connections_drain
    old_ip = frame["old_private_ipv4"].split("/").first
    ds = DB[:pg_stat_activity]
      .where(Sequel.lit("client_addr = ?::inet", old_ip))
      .where(backend_type: "client backend")
      .select(Sequel.function(:count, Sequel.lit("*")))
    count = Integer(postgres_server.run_query(ds), 10)

    Clog.emit("waiting for old NIC connections to drain", {
      aws_nic_migration_drain: {server_ubid: postgres_server.ubid, remaining: count, old_ip: frame["old_private_ipv4"]},
    })

    if count.zero?
      hop_swap_ssh_host
    else
      nap DRAIN_POLL_INTERVAL_SECONDS
    end
  end

  label def swap_ssh_host
    postgres_server.vm.sshable.update(host: frame["new_public_ipv4"])
    postgres_server.vm.sshable.cmd("true")
    hop_disassociate_old_eip
  end

  label def disassociate_old_eip
    old_address = client.describe_addresses(
      filters: [{name: "allocation-id", values: [frame["old_eip_allocation_id"]]}],
    ).addresses.first

    if old_address&.association_id
      client.disassociate_address(association_id: old_address.association_id)
    end
    hop_release_old_eip
  end

  label def release_old_eip
    client.release_address(allocation_id: frame["old_eip_allocation_id"])
    hop_switch_nic_aws_resource
  rescue Aws::EC2::Errors::InvalidAllocationIDNotFound
    hop_switch_nic_aws_resource
  end

  label def switch_nic_aws_resource
    nic.nic_aws_resource.update(
      network_interface_id: frame["new_network_interface_id"],
      eip_allocation_id: frame["new_eip_allocation_id"],
    )
    Clog.emit("AWS NIC migration complete", {
      aws_nic_migration_complete: {server_ubid: postgres_server.ubid, new_network_interface_id: frame["new_network_interface_id"]},
    })
    pop "aws nic migration complete"
  end

  def nic
    @nic ||= postgres_server.vm.nic
  end

  def resource
    @resource ||= postgres_server.resource
  end

  def client
    @client ||= postgres_server.vm.location.location_credential_aws.client
  end
end
# :nocov:
