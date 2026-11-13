# frozen_string_literal: true

require "google/cloud/compute/v1"

class Prog::Test::GcpVpcPeering < Prog::Test::VpcPeeringBase
  include GcpLro

  semaphore :pause, :destroy
  frame_accessor :customer_cidr, :client_zone

  # Ubicloud GCP subnets are random /26s drawn from all of RFC 1918.
  CUSTOMER_CIDRS = %w[192.168.240.0/24 10.255.240.0/24].map { NetAddr::IPv4Net.parse(it) }.freeze
  CLIENT_MACHINE_TYPE = "e2-micro"
  CLIENT_IMAGE = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
  CLIENT_RESULT = /ubie2e result tcp=(ok|fail)/

  def self.assemble
    super(provider: "gcp", project_name: "Gcp-Vpc-Peering-Test-Project")
  end

  label def start
    unless postgres_test_project.gcp_dedicated_subnet_vpcs
      fail_test("Project #{postgres_test_project.ubid} does not give its subnets their own VPC network, so they cannot be peered")
    end
    ui_name = "vpc-peering-e2e-#{strand.ubid}"
    location = Prog::LocationNexus.assemble(display_name: ui_name, name: gcp_location_name, ui_name:,
      visible: true, provider: "gcp", project_id: postgres_test_project_id).subject
    Prog::Test::Base.ensure_gcp_e2e_credential(location)
    target_vm_size, target_storage_size_gib = self.class.gcp_postgres_test_size

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: postgres_test_project_id,
      location_id: location.id,
      name: "postgres-test-vpc-peering",
      target_vm_size:,
      target_storage_size_gib:,
    )

    self.location_id = location.id
    self.postgres_resource_id = st.id
    self.private_subnet_id = st.subject.private_subnet_id
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    nap 10 unless postgres_resource.strand.label == "wait" && representative_server.run_query("SELECT 1") == "1"
    hop_request_refused_peering
  end

  label def request_refused_peering
    st = Prog::Vnet::VpcPeeringNexus.assemble(private_subnet, peer_account_id: gcp_project_id, peer_vpc_id: "projects/#{gcp_project_id}/global/networks/#{missing_network_name}")
    self.vpc_peering_id = st.id
    hop_wait_refused_peering
  end

  label def wait_refused_peering
    if (vpc_peering.state == "failed" && Strand[vpc_peering_id].label == "failed") || vpc_peering.state == "waiting_for_peer"
      vpc_peering.incr_destroy
      hop_wait_refused_peering_destroyed
    end
    wait_or_fail(5 * 60) { "VPC peering with a missing network did not settle within 5 minutes, it is #{peering_progress}" }
    hop_destroy
  end

  label def wait_refused_peering_destroyed
    if vpc_peering
      wait_or_fail(10 * 60) { "VPC peering with a missing network was not destroyed within 10 minutes, it is #{peering_progress}" }
      hop_destroy
    end
    if (failure = ubicloud_half_failure("the VPC peering with a missing network was destroyed", missing_network_name))
      record_failure(failure)
      hop_destroy
    end
    self.vpc_peering_id = nil
    hop_create_customer_network
  end

  label def create_customer_network
    begin
      op = networks_client.insert(
        project: gcp_project_id,
        network_resource: Google::Cloud::Compute::V1::Network.new(
          name: customer_resource_name,
          description: "VPC peering E2E customer network [Ubicloud=#{Config.provider_resource_tag_value}]",
          auto_create_subnetworks: false,
          routing_config: Google::Cloud::Compute::V1::NetworkRoutingConfig.new(routing_mode: "REGIONAL"),
        ),
      )
      save_gcp_op("create_network", op_name: op.name, scope: "global")
    rescue Google::Cloud::AlreadyExistsError
      nil
    end
    Clog.emit("GCP VPC created", {gcp_vpc_created: customer_resource_name})
    hop_wait_customer_network
  end

  label def wait_customer_network
    wait_insert_op("create_network", "Customer network #{customer_resource_name}")
    unless gcp_get(networks_client, network: customer_resource_name)
      wait_or_fail(5 * 60, "Customer network #{customer_resource_name} was not created within 5 minutes")
      hop_destroy
    end
    hop_create_customer_subnet
  end

  label def create_customer_subnet
    self.customer_cidr = CUSTOMER_CIDRS.find { private_subnet.net4.rel(it).nil? }.to_s
    begin
      op = subnetworks_client.insert(
        project: gcp_project_id,
        region: gcp_region,
        subnetwork_resource: Google::Cloud::Compute::V1::Subnetwork.new(
          name: customer_resource_name,
          description: "VPC peering E2E customer subnet [Ubicloud=#{Config.provider_resource_tag_value}]",
          ip_cidr_range: customer_cidr,
          network: customer_network_path,
          stack_type: "IPV4_ONLY",
        ),
      )
      save_gcp_op("create_subnet", op_name: op.name, scope: "region", scope_value: gcp_region)
    rescue Google::Cloud::AlreadyExistsError
      nil
    rescue Google::Cloud::InvalidArgumentError => e
      raise unless e.message.include?("is not ready")
      nap 5
    end
    Clog.emit("GCP subnet created", {gcp_subnet_created: "#{customer_resource_name}@#{gcp_region}"})
    hop_wait_customer_subnet
  end

  label def wait_customer_subnet
    wait_insert_op("create_subnet", "Customer subnet #{customer_resource_name}")
    unless gcp_get(subnetworks_client, region: gcp_region, subnetwork: customer_resource_name)
      wait_or_fail(5 * 60, "Customer subnet #{customer_resource_name} was not created within 5 minutes")
      hop_destroy
    end
    hop_request_peering
  end

  label def request_peering
    st = Prog::Vnet::VpcPeeringNexus.assemble(private_subnet, peer_account_id: gcp_project_id, peer_vpc_id: customer_network_path)
    self.vpc_peering_id = st.id
    # The customer side from the previous peering is still in place.
    hop_wait_peering_active if cascade_peering
    hop_wait_peering_requested
  end

  label def wait_peering_requested
    case vpc_peering.state
    when "waiting_for_peer"
      hop_add_customer_peering
    when "failed"
      record_failure("VPC peering failed: #{vpc_peering.state_message}")
    else
      wait_or_fail(5 * 60, "Ubicloud's side of the VPC peering was not added within 5 minutes, state #{peering_state}")
    end
    hop_destroy
  end

  label def add_customer_peering
    unless customer_peering
      begin
        networks_client.add_peering(
          project: gcp_project_id,
          network: customer_resource_name,
          networks_add_peering_request_resource: Google::Cloud::Compute::V1::NetworksAddPeeringRequest.new(
            network_peering: Google::Cloud::Compute::V1::NetworkPeering.new(
              name: customer_resource_name,
              network: "projects/#{gcp_project_id}/global/networks/#{private_subnet.gcp_vpc.name}",
              exchange_subnet_routes: true,
              stack_type: "IPV4_ONLY",
              import_custom_routes: false,
              export_custom_routes: false,
              import_subnet_routes_with_public_ip: false,
              export_subnet_routes_with_public_ip: false,
            ),
          ),
        )
      rescue Google::Cloud::InvalidArgumentError, Google::Cloud::FailedPreconditionError => e
        raise unless e.message.include?("operation in progress")
        nap 15
      end
    end
    Clog.emit("GCP network peering created", {gcp_network_peering_created: "#{customer_resource_name}@#{customer_resource_name}"})
    hop_wait_peering_active
  end

  label def wait_peering_active
    case vpc_peering.state
    when "active"
      if (failure = active_peering_failure)
        wait_or_fail(5 * 60, failure)
      elsif cascade_peering
        hop_destroy_peered_postgres
      else
        hop_launch_client
      end
    when "failed"
      record_failure("VPC peering failed: #{vpc_peering.state_message}")
    else
      wait_or_fail(5 * 60, "VPC peering did not become active within 5 minutes, state #{peering_state}")
    end
    hop_destroy
  end

  label def launch_client
    zone = "#{gcp_region}-#{representative_server.vm.vm_gcp_resource.location_az.az}"
    begin
      op = compute_client.insert(
        project: gcp_project_id,
        zone:,
        instance_resource: Google::Cloud::Compute::V1::Instance.new(
          name: customer_resource_name,
          machine_type: "zones/#{zone}/machineTypes/#{CLIENT_MACHINE_TYPE}",
          labels: {"ubicloud" => Config.provider_resource_tag_value},
          disks: [
            Google::Cloud::Compute::V1::AttachedDisk.new(
              auto_delete: true,
              boot: true,
              initialize_params: Google::Cloud::Compute::V1::AttachedDiskInitializeParams.new(source_image: CLIENT_IMAGE),
            ),
          ],
          network_interfaces: [
            Google::Cloud::Compute::V1::NetworkInterface.new(
              network: customer_network_path,
              subnetwork: "projects/#{gcp_project_id}/regions/#{gcp_region}/subnetworks/#{customer_resource_name}",
              stack_type: "IPV4_ONLY",
            ),
          ],
          metadata: Google::Cloud::Compute::V1::Metadata.new(
            items: [Google::Cloud::Compute::V1::Items.new(key: "startup-script", value: client_startup_script)],
          ),
        ),
      )
      save_gcp_op("create_client", op_name: op.name, scope: "zone", scope_value: zone)
    rescue Google::Cloud::AlreadyExistsError
      nil
    rescue Google::Cloud::Error => e
      record_failure("Could not launch the client instance: #{e.message}")
      hop_destroy
    end
    self.client_zone = zone
    Clog.emit("GCP instance created", {gcp_instance_created: "#{customer_resource_name}@#{zone}"})
    hop_wait_client_result
  end

  label def wait_client_result
    wait_insert_op("create_client", "Client instance #{customer_resource_name}")
    output = begin
      compute_client.get_serial_port_output(project: gcp_project_id, zone: client_zone, instance: customer_resource_name).contents
    rescue Google::Cloud::NotFoundError
      nil
    rescue Google::Cloud::InvalidArgumentError => e
      raise unless e.message.include?("is not ready")
      nil
    rescue Google::Cloud::PermissionDeniedError => e
      record_failure("Could not read the serial output of client instance #{customer_resource_name}: #{e.message}")
      hop_destroy
    end
    tcp = output.to_s.scan(CLIENT_RESULT).last&.first

    if tcp.nil?
      wait_or_fail(15 * 60, "Client instance #{customer_resource_name} reported no result within 15 minutes")
    elsif tcp == "fail"
      record_failure("From the customer network, TCP to #{postgres_ipv4} port 5432 got fail, expected ok")
    end
    hop_destroy
  end

  label def destroy
    if client_zone
      begin
        compute_client.delete(project: gcp_project_id, zone: client_zone, instance: customer_resource_name)
      rescue Google::Cloud::NotFoundError
        nil
      end
    end
    vpc_peering&.incr_destroy
    hop_wait_peering_destroyed
  end

  label def wait_peering_destroyed
    if vpc_peering
      wait_or_fail(10 * 60) { "VPC peering was not destroyed within 10 minutes, it is #{peering_progress}" }
    elsif vpc_peering_id
      if (failure = ubicloud_half_failure("the VPC peering was destroyed"))
        record_failure(failure)
      elsif (peering = customer_peering) && peering.state != "INACTIVE"
        wait_or_fail(5 * 60, "Peering #{customer_resource_name} on the customer network is #{peering.state} after Ubicloud's side was removed, expected INACTIVE")
      end
    end

    if fail_message.nil? && !cascade_peering
      self.cascade_peering = true
      self.label_deadlines = nil
      hop_request_peering
    end

    hop_wait_client_deleted
  end

  label def wait_peering_cascade
    if vpc_peering
      wait_or_fail(20 * 60) { "VPC peering was not destroyed within 20 minutes of the PostgreSQL destroy, it is #{peering_progress}" }
    end
    if (failure = ubicloud_half_failure("the PostgreSQL destroy"))
      record_failure(failure)
    end
    hop_wait_client_deleted
  end

  label def wait_client_deleted
    if client_zone && gcp_get(compute_client, zone: client_zone, instance: customer_resource_name)
      wait_or_fail(5 * 60, "Client instance #{customer_resource_name} was not deleted within 5 minutes")
      hop_destroy_postgres
    end
    hop_remove_customer_peering
  end

  label def remove_customer_peering
    hop_delete_customer_subnet unless customer_peering
    begin
      networks_client.remove_peering(
        project: gcp_project_id,
        network: customer_resource_name,
        networks_remove_peering_request_resource: Google::Cloud::Compute::V1::NetworksRemovePeeringRequest.new(name: customer_resource_name),
      )
    rescue Google::Cloud::NotFoundError
      nil
    rescue Google::Cloud::InvalidArgumentError, Google::Cloud::FailedPreconditionError => e
      raise unless e.message.include?("operation in progress")
      nap 15
    end
    hop_wait_customer_peering_removed
  end

  label def wait_customer_peering_removed
    if customer_peering
      wait_or_fail(5 * 60, "Peering #{customer_resource_name} on the customer network was not removed within 5 minutes")
      hop_destroy_postgres
    end
    hop_delete_customer_subnet
  end

  label def delete_customer_subnet
    delete_customer_resource("Customer subnet #{customer_resource_name}") {
      subnetworks_client.delete(project: gcp_project_id, region: gcp_region, subnetwork: customer_resource_name)
    }
    hop_wait_customer_subnet_deleted
  end

  label def wait_customer_subnet_deleted
    if gcp_get(subnetworks_client, region: gcp_region, subnetwork: customer_resource_name)
      wait_or_fail(5 * 60, "Customer subnet #{customer_resource_name} was not deleted within 5 minutes")
      hop_destroy_postgres
    end
    hop_delete_customer_network
  end

  label def delete_customer_network
    delete_customer_resource("Customer network #{customer_resource_name}") {
      networks_client.delete(project: gcp_project_id, network: customer_resource_name)
    }
    hop_wait_customer_network_deleted
  end

  label def wait_customer_network_deleted
    if gcp_get(networks_client, network: customer_resource_name)
      wait_or_fail(5 * 60, "Customer network #{customer_resource_name} was not deleted within 5 minutes")
    end
    hop_destroy_postgres
  end

  def credential
    @credential ||= Location[location_id].location_credential_gcp
  end

  def gcp_project_id
    credential.project_id
  end

  def gcp_region
    gcp_location_name.delete_prefix("gcp-")
  end

  def networks_client
    credential.networks_client
  end

  def subnetworks_client
    credential.subnetworks_client
  end

  def compute_client
    credential.compute_client
  end

  def customer_resource_name
    "vpc-peering-e2e-#{strand.ubid}"
  end

  def customer_network_path
    "projects/#{gcp_project_id}/global/networks/#{customer_resource_name}"
  end

  def missing_network_name
    "#{customer_resource_name}-missing"
  end

  # The database has no DNS zone in the E2E, and GCP internal DNS does not cross peerings.
  def postgres_ipv4
    representative_server.vm.private_ipv4_string
  end

  def gcp_get(client, **)
    client.get(project: gcp_project_id, **)
  rescue Google::Cloud::NotFoundError
    nil
  end

  def network_peerings(network)
    gcp_get(networks_client, network:)&.peerings || [].freeze
  end

  def customer_peering
    network_peerings(customer_resource_name).find { it.name == customer_resource_name }
  end

  # The subnet destroy drops the join row before the network.
  def ubicloud_half(network = customer_resource_name)
    return unless (vpc = GcpVpc[dedicated_for_subnet_id: private_subnet_id])
    network_peerings(vpc.name).find { it.network.end_with?("/networks/#{network}") }
  end

  def ubicloud_half_failure(after, network = customer_resource_name)
    if (half = ubicloud_half(network))
      "Ubicloud's side of the peering (#{half.name}) is #{half.state} after #{after}"
    end
  end

  def peering_state
    vpc_peering.state_message ? "#{vpc_peering.state}: #{vpc_peering.state_message}" : vpc_peering.state
  end

  def wait_insert_op(name, resource)
    return unless frame[name]
    poll_and_clear_gcp_op(name) do |op|
      record_failure("#{resource} could not be created: #{op_error_message(op)}")
      hop_destroy
    end
  end

  def active_peering_failure
    if vpc_peering.peer_cidrs.map(&:to_s) != [customer_cidr]
      "VPC peering routes #{vpc_peering.peer_cidrs.map(&:to_s)}, expected [#{customer_cidr}]"
    elsif (state = ubicloud_half&.state) != "ACTIVE"
      "Ubicloud's side of the peering is #{state || "missing"}, expected ACTIVE"
    # A settled wait naps 15 minutes; a raising one backs off with try above 0.
    elsif (pst = Strand[vpc_peering_id]).label != "wait" || pst.try != 0 || pst.schedule < Time.now + 5 * 60
      "VPC peering has not settled in wait, it is in #{pst.label} (try #{pst.try})"
    elsif vpc_peering.state_message
      "VPC peering is active with warnings: #{vpc_peering.state_message}"
    end
  end

  def delete_customer_resource(resource)
    yield
  rescue Google::Cloud::NotFoundError
    nil
  rescue Google::Cloud::InvalidArgumentError => e
    raise unless e.message.include?("being used by")
    wait_or_fail(5 * 60, "#{resource} could not be deleted within 5 minutes")
    hop_destroy_postgres
  end

  # The client has no public address, so it reports through the serial console.
  def client_startup_script
    <<~SH
      #!/bin/bash
      shutdown -h +60
      tcp=fail
      for i in $(seq 30); do
        timeout 5 bash -c "exec 3<>/dev/tcp/#{postgres_ipv4}/5432" && tcp=ok && break
        sleep 10
      done
      echo "ubie2e result tcp=$tcp" >/dev/ttyS0
    SH
  end
end
