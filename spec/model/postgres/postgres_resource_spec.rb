# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  subject(:postgres_resource) {
    pr = described_class.create(
      name: "pg-name",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id:,
      project_id: project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    )
    fw = Firewall.create(name: pr.ubid + "-internal-firewall", project_id: project.id, location_id:)
    fw.associate_with_private_subnet(private_subnet)

    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait")
    pr
  }

  let(:project) { Project.create(name: "pg-test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:location) { Location[location_id] }
  let(:timeline) { PostgresTimeline.create(location_id:) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  it "returns connection string without ubid qualifier" do
    expect(postgres_resource).to receive(:dns_zone).and_return("something").at_least(:once)
    expect(postgres_resource).to receive(:hostname_version).and_return("v1")
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.postgres.ubicloud.com:5432/postgres?channel_binding=require")
  end

  it "returns connection string with ubid qualifier" do
    postgres_resource.update(hostname_version: "v2")
    expect(postgres_resource).to receive(:dns_zone).and_return("something").at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com:5432/postgres?channel_binding=require")
  end

  it "returns connection string with ip address if config is not set" do
    vm = create_hosted_vm(project, private_subnet, "pg-vm")
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: "1.2.3.4/32")
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@1.2.3.4:5432/postgres?channel_binding=require")
  end

  it "returns connection string as nil if there is no server" do
    # No server created, no dns_zone
    expect(postgres_resource.connection_string).to be_nil
  end

  it "returns replication connection string as nil if there is no server" do
    # No server created, no dns_zone
    expect(postgres_resource.replication_connection_string(application_name: "pgubidstandby")).to be_nil
  end

  it "returns replication_connection_string" do
    expect(postgres_resource).to receive(:dns_zone).and_return(instance_double(DnsZone)).at_least(:once)
    s = postgres_resource.replication_connection_string(application_name: "pgubidstandby")
    expect(s).to include("ubi_replication@#{postgres_resource.ubid}.postgres.ubicloud.com", "application_name=pgubidstandby", "sslcert=/etc/ssl/certs/server.crt")
  end

  it "returns replication_connection_string with ip when no dns_zone exists" do
    vm = create_hosted_vm(project, private_subnet, "pg-vm")
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: "1.2.3.4/32")
    expect(postgres_resource.dns_zone).to be_nil
    s = postgres_resource.replication_connection_string(application_name: "pgubidstandby")
    expect(s).to include("ubi_replication@1.2.3.4", "application_name=pgubidstandby", "sslcert=/etc/ssl/certs/server.crt")
  end

  describe "#provision_new_standby" do
    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(project.id)
    end

    let(:vm1) { create_hosted_vm(project, private_subnet, "pg-vm-1") }
    let(:vm2) { create_hosted_vm(project, private_subnet, "pg-vm-2") }
    let(:ps1) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm1.id,
        synchronization_status: "ready", timeline_access: "push", version: "16")
    }
    let(:ps2) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm2.id,
        synchronization_status: "ready", timeline_access: "push", version: "16")
    }

    it "provisions a new server without excluding hosts when Config.allow_unspread_servers is true for regular instances" do
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      ps1
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_data_centers: [])).and_call_original

      postgres_resource.provision_new_standby
      expect(PostgresServer.count).to eq(2)
      new_server = PostgresServer.exclude(id: ps1.id).first
      expect(new_server).not_to be_nil
      expect(new_server.resource_id).to eq(postgres_resource.id)
      expect(new_server.timeline_access).to eq("fetch")
      expect(new_server.vm.vm_firewalls).to eq([postgres_resource.internal_firewall])
      expect(new_server.vm.strand.stack[0]["exclude_data_centers"]).to eq([])
    end

    it "provisions a new server but excludes currently used data centers" do
      allow(Config).to receive(:allow_unspread_servers).and_return(false)
      ps1
      ps2
      vm_host_1 = create_vm_host
      vm_host_1.update(data_center: "dc1")
      vm1.update(vm_host_id: vm_host_1.id)
      vm2.update(vm_host_id: vm_host_1.id)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_data_centers: ["dc1"])).and_call_original
      postgres_resource.provision_new_standby
      expect(postgres_resource.reload.servers.count).to eq(3)
      new_server = PostgresServer.exclude(id: [ps1.id, ps2.id]).order(:created_at).last
      expect(new_server.vm.strand.stack[0]["exclude_data_centers"]).to eq(["dc1"])
    end

    it "provisions a new server but excludes currently used az for aws" do
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::AWS_PROVIDER_NAME).at_least(:once)
      ps1
      ps2
      NicAwsResource.create_with_id(vm1.nic.id, subnet_az: "a")

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_availability_zones: ["a"])).and_call_original
      expect(postgres_resource).to receive(:use_different_az_set?).and_return(true)

      postgres_resource.provision_new_standby
      expect(PostgresServer.count).to eq(3)
      new_server = PostgresServer.exclude(id: [ps1.id, ps2.id]).first
      expect(new_server.resource_id).to eq(postgres_resource.id)
      expect(new_server.vm.nic.strand.stack[0]["exclude_availability_zones"]).to eq(["a"])
    end

    it "provisions a new server in a used az for aws if use_different_az_set? is false" do
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::AWS_PROVIDER_NAME).at_least(:once)
      ps1
      ps2
      NicAwsResource.create_with_id(vm1.nic.id, subnet_az: "a")
      NicAwsResource.create_with_id(vm2.nic.id, subnet_az: "b")

      expect(postgres_resource).to receive(:representative_server).and_return(ps1)
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(availability_zone: "a")).and_call_original
      expect(postgres_resource).to receive(:use_different_az_set?).and_return(false)

      postgres_resource.provision_new_standby
      expect(postgres_resource.reload.servers.count).to eq(3)
      new_server = PostgresServer.exclude(id: [ps1.id, ps2.id]).first
      expect(new_server.vm.nic.strand.stack[0]["availability_zone"]).to eq("a")
    end

    it "provisions a new server with the correct timeline for a regular instance" do
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      allow(postgres_resource).to receive_messages(read_replica?: false, timeline:)
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::HETZNER_PROVIDER_NAME).at_least(:once)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(timeline_id: timeline.id)).and_call_original

      new_server = postgres_resource.provision_new_standby.subject
      expect(new_server).not_to be_nil
      expect(new_server.timeline_id).to eq(timeline.id)
      expect(new_server.vm.strand.stack[0]["exclude_host_ids"]).to eq([])
    end

    it "provisions a new server with the correct timeline for a read replica" do
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      parent_timeline = PostgresTimeline.create(location_id:)
      parent_resource = instance_double(described_class, timeline: parent_timeline)
      allow(postgres_resource).to receive_messages(read_replica?: true, parent: parent_resource)
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::HETZNER_PROVIDER_NAME).at_least(:once)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(timeline_id: parent_timeline.id)).and_call_original

      expect { postgres_resource.provision_new_standby }.to change(PostgresServer, :count).by(1)
      new_server = PostgresServer.order(:created_at).last
      expect(new_server.timeline_id).to eq(parent_timeline.id)
      expect(new_server.vm.strand.stack[0]["exclude_host_ids"]).to eq([])
    end

    it "provisions a new server excluding the representative server's host for leaseweb" do
      allow(Config).to receive(:allow_unspread_servers).and_return(false)
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::LEASEWEB_PROVIDER_NAME).at_least(:once)
      ps1
      vm_host = create_vm_host
      vm1.update(vm_host_id: vm_host.id)
      ps1.update(is_representative: true)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: [vm_host.id])).and_call_original

      postgres_resource.provision_new_standby
      expect(postgres_resource.reload.servers.count).to eq(2)
      new_server = PostgresServer.exclude(id: ps1.id).first
      expect(new_server.vm.strand.stack[0]["exclude_host_ids"]).to eq([vm_host.id])
    end

    it "provisions a new server with empty exclude_host_ids for leaseweb when there is no representative server" do
      allow(Config).to receive(:allow_unspread_servers).and_return(false)
      allow(postgres_resource).to receive_messages(read_replica?: false, timeline:)
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::LEASEWEB_PROVIDER_NAME).at_least(:once)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: [])).and_call_original

      postgres_resource.provision_new_standby
      expect(postgres_resource.reload.servers.count).to eq(1)
      new_server = PostgresServer.first
      expect(new_server.vm.strand.stack[0]["exclude_host_ids"]).to eq([])
    end
  end

  it "returns has_enough_fresh_servers correctly" do
    # Create a server that doesn't need recycling (matches target_vm_size, target_storage_size_gib, target_version)
    vm = create_hosted_vm(project, private_subnet, "pg-vm-fresh")
    vm_host = create_vm_host
    storage_device = StorageDevice.create(name: "nvme0", vm_host_id: vm_host.id, total_storage_gib: 100, available_storage_gib: 80)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1, storage_device_id: storage_device.id)
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "17")

    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.has_enough_fresh_servers?).to be(true)
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.has_enough_fresh_servers?).to be(false)
  end

  it "returns has_enough_fresh_servers correctly during upgrades" do
    # Create representative server with version 16 so version returns "16"
    vm_rep = create_hosted_vm(project, private_subnet, "pg-vm-rep")
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm_rep.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16")

    # Set target_version to trigger upgrade path (version < target_version)
    postgres_resource.update(target_version: "17")

    # Create candidate server
    vm = create_hosted_vm(project, private_subnet, "pg-vm-fresh")
    candidate_server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "17")

    # Stub consecutive returns: first candidate exists, then nil (tests both branches)
    expect(postgres_resource).to receive(:upgrade_candidate_server).and_return(candidate_server, nil)
    expect(postgres_resource.has_enough_fresh_servers?).to be(true)
    expect(postgres_resource.has_enough_fresh_servers?).to be(false)
  end

  describe "#upgrade_candidate_server" do
    let(:vm_host) { create_vm_host }
    let(:storage_device) {
      StorageDevice.create(
        name: "nvme0", vm_host_id: vm_host.id,
        total_storage_gib: 100, available_storage_gib: 80
      )
    }

    def create_server_with_boot_image(boot_image_version:, is_representative: false, created_offset: 0)
      vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
      boot_image = BootImage.create(
        name: "postgres-ubuntu-#{SecureRandom.hex(4)}", version: boot_image_version,
        vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 10
      )
      VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 64, disk_index: 0,
        storage_device_id: storage_device.id, boot_image_id: boot_image.id
      )
      PostgresServer.create(
        timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative:,
        created_at: Time.now + created_offset,
        synchronization_status: "ready", timeline_access: "push", version: "17"
      )
    end

    it "returns candidate when available and location is not aws" do
      # Primary server
      create_server_with_boot_image(boot_image_version: "20240801", is_representative: true)
      # Standby servers with valid boot image
      create_server_with_boot_image(boot_image_version: "20240801", created_offset: -3600)
      standby2 = create_server_with_boot_image(boot_image_version: "20240801", created_offset: 0)

      # Should return the standby with latest created_at
      expect(postgres_resource.upgrade_candidate_server).to eq(standby2)
    end

    it "returns nil when candidate is not available and location is not aws" do
      # Primary server
      create_server_with_boot_image(boot_image_version: "20240801", is_representative: true)
      # Standby servers with old boot image (< 20240801)
      create_server_with_boot_image(boot_image_version: "20240729", created_offset: -3600)
      create_server_with_boot_image(boot_image_version: "20240729", created_offset: 0)

      expect(postgres_resource.upgrade_candidate_server).to be_nil
    end

    it "returns candidate when available and location is aws" do
      # Create AWS location
      aws_location = Location.create(
        name: "us-west-2", provider: "aws", display_name: "aws-us-west-2",
        ui_name: "AWS US West 2", visible: true
      )
      aws_subnet = PrivateSubnet.create(
        name: "aws-subnet", project_id: project.id, location_id: aws_location.id,
        net4: "172.0.1.0/26", net6: "fdfa:b5aa:14a3:4a3e::/64"
      )
      aws_timeline = PostgresTimeline.create(location_id: aws_location.id)
      aws_resource = described_class.create(
        name: "pg-aws", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: aws_location.id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64
      )

      # Create VMs with AWS boot images
      vm1 = Prog::Vm::Nexus.assemble_with_sshable(
        project.id, name: "aws-vm-1", private_subnet_id: aws_subnet.id,
        location_id: aws_location.id, unix_user: "ubi", boot_image: "ami-12345678"
      ).subject

      vm2 = Prog::Vm::Nexus.assemble_with_sshable(
        project.id, name: "aws-vm-2", private_subnet_id: aws_subnet.id,
        location_id: aws_location.id, unix_user: "ubi", boot_image: "ami-87654321"
      ).subject

      vm3 = Prog::Vm::Nexus.assemble_with_sshable(
        project.id, name: "aws-vm-3", private_subnet_id: aws_subnet.id,
        location_id: aws_location.id, unix_user: "ubi", boot_image: "ami-primary"
      ).subject

      # Create PgAwsAmi for the first AMI only
      PgAwsAmi.create(aws_ami_id: "ami-12345678", arch: "x64")

      # Primary
      PostgresServer.create(
        timeline: aws_timeline, resource_id: aws_resource.id, vm_id: vm3.id,
        is_representative: true, synchronization_status: "ready",
        timeline_access: "push", version: "17"
      )
      # Standby with valid AMI (older)
      standby1 = PostgresServer.create(
        timeline: aws_timeline, resource_id: aws_resource.id, vm_id: vm1.id,
        is_representative: false, created_at: Time.now - 3600,
        synchronization_status: "ready", timeline_access: "push", version: "17"
      )
      # Standby with invalid AMI (newer)
      PostgresServer.create(
        timeline: aws_timeline, resource_id: aws_resource.id, vm_id: vm2.id,
        is_representative: false, created_at: Time.now,
        synchronization_status: "ready", timeline_access: "push", version: "17"
      )

      expect(aws_resource.upgrade_candidate_server).to eq(standby1)
    end
  end

  it "returns has_enough_ready_servers correctly when not upgrading" do
    # Create a server that doesn't need recycling and has strand.label == "wait"
    vm = create_hosted_vm(project, private_subnet, "pg-vm-ready")
    vm_host = create_vm_host
    storage_device = StorageDevice.create(name: "nvme0", vm_host_id: vm_host.id, total_storage_gib: 100, available_storage_gib: 80)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1, storage_device_id: storage_device.id)
    server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "17")
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")

    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.has_enough_ready_servers?).to be(true)
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is not present" do
    # Create representative server with version 16
    vm_rep = create_hosted_vm(project, private_subnet, "pg-vm-rep-no-candidate")
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm_rep.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16")
    postgres_resource.update(target_version: "17")

    # No upgrade_candidate_server exists (would need specific boot image setup)
    expect(postgres_resource).to receive(:upgrade_candidate_server).at_least(:once).and_return(nil)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is not in wait state" do
    # Create representative server with version 16
    vm_rep = create_hosted_vm(project, private_subnet, "pg-vm-rep-not-ready")
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm_rep.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16")
    postgres_resource.update(target_version: "17")

    vm = create_hosted_vm(project, private_subnet, "pg-vm-candidate-not-ready")
    candidate_server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "17")
    Strand.create_with_id(candidate_server, prog: "Postgres::PostgresServerNexus", label: "wait_bootstrap_rhizome")

    expect(postgres_resource).to receive(:upgrade_candidate_server).at_least(:once).and_return(candidate_server)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is ready" do
    # Create representative server with version 16
    vm_rep = create_hosted_vm(project, private_subnet, "pg-vm-rep-ready")
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm_rep.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16")
    postgres_resource.update(target_version: "17")

    vm = create_hosted_vm(project, private_subnet, "pg-vm-candidate-ready")
    candidate_server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "17")
    Strand.create_with_id(candidate_server, prog: "Postgres::PostgresServerNexus", label: "wait")

    expect(postgres_resource).to receive(:upgrade_candidate_server).at_least(:once).and_return(candidate_server)
    expect(postgres_resource.has_enough_ready_servers?).to be(true)
  end

  it "returns needs_convergence correctly when server needs recycling" do
    vm = create_hosted_vm(project, private_subnet, "pg-vm-needs-recycle")
    # Create server with version 16 while target_version is 17 -> needs_recycling? returns true
    server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "16")
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")

    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.needs_convergence?).to be(true)
  end

  it "returns needs_convergence correctly when server count mismatch" do
    vm = create_hosted_vm(project, private_subnet, "pg-vm-count-mismatch")
    vm_host = create_vm_host
    storage_device = StorageDevice.create(name: "nvme0", vm_host_id: vm_host.id, total_storage_gib: 100, available_storage_gib: 80)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1, storage_device_id: storage_device.id)
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "17")

    # 1 server but ha_type requires 2
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.needs_convergence?).to be(true)
  end

  it "returns needs_convergence correctly when no convergence needed" do
    vm = create_hosted_vm(project, private_subnet, "pg-vm-no-converge")
    vm_host = create_vm_host
    storage_device = StorageDevice.create(name: "nvme0", vm_host_id: vm_host.id, total_storage_gib: 100, available_storage_gib: 80)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1, storage_device_id: storage_device.id)
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      synchronization_status: "ready", timeline_access: "push", version: "17")

    # 1 server, ha_type requires 1, no recycling needed
    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.needs_convergence?).to be(false)
  end

  it "returns needs_convergence correctly when upgrading" do
    vm = create_hosted_vm(project, private_subnet, "pg-vm-upgrade-converge")
    vm_host = create_vm_host
    storage_device = StorageDevice.create(name: "nvme0", vm_host_id: vm_host.id, total_storage_gib: 100, available_storage_gib: 80)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1, storage_device_id: storage_device.id)
    server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16")
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")

    # version 16, target 17 -> needs upgrade
    postgres_resource.update(ha_type: PostgresResource::HaType::NONE, target_version: "17")
    expect(postgres_resource.needs_convergence?).to be(true)
  end

  it "#pg_firewall_rules returns empty array when there is no customer firewall" do
    # Set up private_subnet so customer_firewall query works (returns nil since no matching firewall)
    postgres_resource.update(private_subnet_id: private_subnet.id)
    expect(postgres_resource.pg_firewall_rules).to eq []
  end

  describe "display_state" do
    def create_representative_server(strand_label:)
      vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
      server = PostgresServer.create(
        timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready",
        timeline_access: "push", version: "17"
      )
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: strand_label)
      server
    end

    it "returns 'deleting' when destroy semaphore is set" do
      postgres_resource.incr_destroy
      expect(postgres_resource.display_state).to eq("deleting")
    end

    it "returns 'deleting' when destroying semaphore is set" do
      postgres_resource.incr_destroying
      expect(postgres_resource.display_state).to eq("deleting")
    end

    it "returns 'unavailable' when representative server's strand label is 'unavailable'" do
      create_representative_server(strand_label: "unavailable")
      expect(postgres_resource.display_state).to eq("unavailable")
    end

    it "returns 'restoring_backup' when representative server's strand label is 'initialize_database_from_backup'" do
      create_representative_server(strand_label: "initialize_database_from_backup")
      expect(postgres_resource.display_state).to eq("restoring_backup")
    end

    it "returns 'replaying_wal' when representative server's strand label is 'wait_catch_up'" do
      create_representative_server(strand_label: "wait_catch_up")
      expect(postgres_resource.display_state).to eq("replaying_wal")
    end

    it "returns 'replaying_wal' when representative server's strand label is 'wait_synchronization'" do
      create_representative_server(strand_label: "wait_synchronization")
      expect(postgres_resource.display_state).to eq("replaying_wal")
    end

    it "returns 'finalizing_restore' when representative server's strand label is 'wait_recovery_completion'" do
      create_representative_server(strand_label: "wait_recovery_completion")
      expect(postgres_resource.display_state).to eq("finalizing_restore")
    end

    it "returns 'restarting' when representative server's strand label is 'restart'" do
      create_representative_server(strand_label: "restart")
      expect(postgres_resource.display_state).to eq("restarting")
    end

    it "returns 'running' when strand label is 'wait' and has no children" do
      # The strand already has label "wait" from subject, no children by default
      expect(postgres_resource.display_state).to eq("running")
    end

    it "returns 'creating' when strand is 'wait_server'" do
      postgres_resource.strand.update(label: "wait_server")
      expect(postgres_resource.display_state).to eq("creating")
    end
  end

  it "returns in_maintenance_window? correctly" do
    # nil maintenance_window means always in maintenance window
    postgres_resource.update(maintenance_window_start_at: nil)
    expect(postgres_resource.in_maintenance_window?).to be(true)

    # With specific window hour, test time-based logic
    postgres_resource.update(maintenance_window_start_at: 1)
    expect(Time).to receive(:now).and_return(Time.parse("2025-05-01 02:00:00Z"), Time.parse("2025-05-01 04:00:00Z"), Time.parse("2025-05-01 00:00:00Z"))
    expect(postgres_resource.in_maintenance_window?).to be(true)
    expect(postgres_resource.in_maintenance_window?).to be(false)
    expect(postgres_resource.in_maintenance_window?).to be(false)
  end

  it "returns target_standby_count correctly" do
    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.target_standby_count).to eq(0)
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.target_standby_count).to eq(1)
    postgres_resource.update(ha_type: PostgresResource::HaType::SYNC)
    expect(postgres_resource.target_standby_count).to eq(2)
  end

  it "returns target_server_count correctly" do
    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.target_server_count).to eq(1)
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.target_server_count).to eq(2)
    postgres_resource.update(ha_type: PostgresResource::HaType::SYNC)
    expect(postgres_resource.target_server_count).to eq(3)
  end

  describe "#ongoing_failover?" do
    def create_server_with_strand(label:)
      vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
      server = PostgresServer.create(
        timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        synchronization_status: "ready", timeline_access: "push", version: "17"
      )
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label:)
      server
    end

    it "returns false if there is no ongoing failover" do
      create_server_with_strand(label: "wait")
      create_server_with_strand(label: "wait")
      expect(postgres_resource.ongoing_failover?).to be false
    end

    it "returns true if there is an ongoing failover" do
      create_server_with_strand(label: "taking_over")
      create_server_with_strand(label: "wait")
      expect(postgres_resource.ongoing_failover?).to be true
    end
  end

  describe "#hostname_suffix" do
    it "returns default hostname suffix if project is nil" do
      # project_id is validated as required, but code defensively handles nil project
      allow(postgres_resource).to receive(:project).and_return(nil)
      expect(postgres_resource.hostname_suffix).to eq(Config.postgres_service_hostname)
    end
  end

  describe "#upgrade_stage" do
    it "returns nil if there's no ongoing upgrade" do
      # No child strands by default
      expect(postgres_resource.upgrade_stage).to be_nil
    end

    it "returns the upgrade stage if there's an ongoing upgrade" do
      # Create child strand with the ConvergePostgresResource prog
      Strand.create(
        prog: "Postgres::ConvergePostgresResource",
        label: "upgrade_standby",
        parent_id: postgres_resource.strand.id
      )
      expect(postgres_resource.upgrade_stage).to eq("upgrade_standby")
    end
  end

  describe "#upgrade_status" do
    it "returns failed if the postgres resource upgrade failed" do
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "upgrade_failed", parent_id: postgres_resource.strand.id)
      expect(postgres_resource.upgrade_status).to eq("failed")
    end

    it "returns not_running if the postgres resource does not need upgrade" do
      # No child strands, version == target_version (default)
      expect(postgres_resource.upgrade_status).to eq("not_running")
    end

    it "returns running if the postgres resource upgrade is in progress" do
      # Create child strand with upgrade label and ensure target_version != version
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby", parent_id: postgres_resource.strand.id)
      postgres_resource.update(target_version: "17")
      # version returns representative_server.version or target_version, so create server with version 16
      vm = create_hosted_vm(project, private_subnet, "pg-vm-upgrade")
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative: true,
        synchronization_status: "ready", timeline_access: "push", version: "16")
      expect(postgres_resource.upgrade_status).to eq("running")
    end
  end

  describe "#can_upgrade?" do
    it "returns true if the postgres resource can be upgraded" do
      postgres_resource.update(target_version: "16", flavor: PostgresResource::Flavor::STANDARD)
      expect(postgres_resource.can_upgrade?).to be true
    end

    it "returns false if the postgres resource cannot be upgraded" do
      postgres_resource.update(target_version: "17", flavor: PostgresResource::Flavor::LANTERN)
      expect(postgres_resource.can_upgrade?).to be false
    end
  end

  describe "#ready_for_read_replica?" do
    it "returns true if the postgres resource is ready for read replica" do
      allow(postgres_resource).to receive(:needs_convergence?).and_return(false)
      allow(PostgresTimeline).to receive(:earliest_restore_time).with(postgres_resource.timeline).and_return(Time.now - 3600)
      expect(postgres_resource.ready_for_read_replica?).to be true
    end

    it "returns false if the postgres resource needs convergence" do
      allow(postgres_resource).to receive(:needs_convergence?).and_return(true)
      expect(postgres_resource.ready_for_read_replica?).to be false
    end

    it "returns false if there is no earliest restore time" do
      allow(postgres_resource).to receive(:needs_convergence?).and_return(false)
      allow(PostgresTimeline).to receive(:earliest_restore_time).with(postgres_resource.timeline).and_return(nil)
      expect(postgres_resource.ready_for_read_replica?).to be false
    end
  end

  describe "#handle_storage_auto_scale" do
    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-auto-scale") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    before do
      VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
      server
      account = Account.create(email: "test@example.com")
      account.add_project(project)
      AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: ActionType::NAME_MAP["Postgres:view"])
      account_with_no_access = Account.create(email: "test2@example.com")
      account_with_no_access.add_project(project)
      allow(Util).to receive(:send_email)
      allow(postgres_resource).to receive(:representative_server).and_return(server)
    end

    it "returns early if representative server is nil" do
      expect(postgres_resource).to receive(:representative_server).and_return(nil)
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "returns early and logs if disk usage check fails" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_raise(RuntimeError, "connection refused")
      expect(Clog).to receive(:emit).with("Failed to check disk usage for #{postgres_resource.ubid}, skipping storage auto-scale check", server)
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "clears semaphores when usage drops below 77% and no pages exist" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  70%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_canceled

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_canceled").count).to eq(0)
    end

    it "clears semaphores and resolves pages when usage drops below 77%" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  70%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_action_performed_85
      postgres_resource.incr_storage_auto_scale_action_performed_90

      Prog::PageNexus.assemble("test", ["PGStorageAutoScaleMaxSize", postgres_resource.id], postgres_resource.ubid)
      Prog::PageNexus.assemble("test", ["PGStorageAutoScaleQuotaInsufficient", postgres_resource.id], postgres_resource.ubid)
      Prog::PageNexus.assemble("test", ["PGStorageAutoScaleCanceled", postgres_resource.id], postgres_resource.ubid)

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_90").count).to eq(0)
      expect(Semaphore.where(strand_id: Page.from_tag_parts("PGStorageAutoScaleMaxSize", postgres_resource.id).id, name: "resolve").count).to eq(1)
      expect(Semaphore.where(strand_id: Page.from_tag_parts("PGStorageAutoScaleQuotaInsufficient", postgres_resource.id).id, name: "resolve").count).to eq(1)
      expect(Semaphore.where(strand_id: Page.from_tag_parts("PGStorageAutoScaleCanceled", postgres_resource.id).id, name: "resolve").count).to eq(1)
    end

    it "clears semaphores with hysteresis (3% below threshold)" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  78%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_action_performed_85
      postgres_resource.incr_storage_auto_scale_action_performed_90

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_90").count).to eq(0)
    end

    it "returns early when usage < 80%" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  79%\n")
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "returns early when usage 80-84% and 80% action already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  83%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "returns early when usage 85-89% and 85% action already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  88%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_85
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "returns early when 90% action already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  95%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_90
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "does not duplicate semaphores that are already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_action_performed_85

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_90").count).to eq(1)
    end

    it "returns early when auto-scale is already in progress" do
      postgres_resource.update(target_storage_size_gib: 128)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "sends warning email at 80-89% with next option available" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(1)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/When disk usage reaches 90%, storage will be automatically increased/))
      )
    end

    it "creates page and sends warning email at 80-89% when at max size" do
      server.vm.update(vcpus: 60, cpu_percent_limit: 6000)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 4096)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Page.from_tag_parts("PGStorageAutoScaleMaxSize", postgres_resource.id)).not_to be_nil
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/However, your database has already reached the maximum available storage size, so auto-scaling cannot proceed./))
      )
    end

    it "creates page and sends warning email at 80-89% when quota insufficient" do
      server.vm.update(vcpus: 16, cpu_percent_limit: 1600)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 2048)
      project.add_quota(quota_id: ProjectQuota.default_quotas["PostgresVCpu"]["id"], value: 16)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Page.from_tag_parts("PGStorageAutoScaleQuotaInsufficient", postgres_resource.id)).not_to be_nil
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/However, your project does not have sufficient quota, so auto-scaling cannot proceed./))
      )
    end

    it "triggers auto-scale at 90%+ with next option available and sufficient quota" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(postgres_resource.reload.target_vm_size).to eq("standard-2")
      expect(postgres_resource.target_storage_size_gib).to eq(128)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/We are currently preparing a new server with increased storage./))
      )
    end

    it "allows hobby instances to upgrade to standard family during auto-scale" do
      postgres_resource.update(target_vm_size: "hobby-2", target_storage_size_gib: 128)
      server.vm.update(family: "burstable", cpu_percent_limit: 100)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 128)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(postgres_resource.reload.target_vm_size).to eq("standard-2")
      expect(postgres_resource.target_storage_size_gib).to eq(256)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/instance is being upgraded from hobby-2 to standard-2/))
      )
    end

    it "still sends an email at 90%+ when at max size" do
      server.vm.update(vcpus: 60, cpu_percent_limit: 6000)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 4096)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/However, your database has already reached the maximum available storage size./))
      )
    end

    it "sends warning at 80-89% when canceled" do
      postgres_resource.incr_storage_auto_scale_canceled
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/you previously canceled auto-scaling/))
      )
    end

    it "does not update targets at 90%+ when canceled but still sends email" do
      postgres_resource.incr_storage_auto_scale_canceled
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(postgres_resource.reload.target_storage_size_gib).to eq(64)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/you previously canceled auto-scaling/))
      )
    end

    it "updates read replicas alongside the primary when auto-scaling" do
      read_replica = described_class.create(
        name: "pg-replica", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id:, project_id: project.id, user_config: {},
        pgbouncer_user_config: {}, target_vm_size: "standard-2", target_storage_size_gib: 64,
        parent_id: postgres_resource.id
      )

      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(read_replica.reload.target_vm_size).to eq("standard-2")
      expect(read_replica.reload.target_storage_size_gib).to eq(128)
    end
  end

  describe "#send_storage_auto_scale_warning_email" do
    before do
      Account.create(email: "user@example.com").add_project(project)
      allow(Util).to receive(:send_email)
      server
    end

    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-email") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    it "includes vm upgrade info when target size differs" do
      next_option = {"size" => "standard-4", "storage_size" => 256}
      postgres_resource.send_storage_auto_scale_warning_notification(85, next_option, nil)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("instance will also be upgraded")
      end
    end

    it "includes read replica info when read replicas exist" do
      described_class.create(
        name: "pg-rr", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id:, project_id: project.id, user_config: {},
        pgbouncer_user_config: {}, target_vm_size: "standard-2", target_storage_size_gib: 64,
        parent_id: postgres_resource.id
      )

      next_option = {"size" => "standard-2", "storage_size" => 128}
      postgres_resource.send_storage_auto_scale_warning_notification(85, next_option, nil)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("read replica(s)")
      end
    end
  end

  describe "#send_storage_auto_scale_started_email" do
    before do
      Account.create(email: "user@example.com").add_project(project)
      allow(Util).to receive(:send_email)
      server
    end

    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-started-email") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    it "includes vm upgrade info when target size differs" do
      next_option = {"size" => "standard-4", "storage_size" => 256}
      postgres_resource.send_storage_auto_scale_started_notification(92, next_option, nil)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("instance is being upgraded")
      end
    end

    it "includes quota_insufficient info" do
      postgres_resource.send_storage_auto_scale_started_notification(92, nil, :quota_insufficient)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("sufficient quota")
      end
    end
  end

  describe "#send_storage_auto_scale_canceled_email" do
    before do
      account = Account.create(email: "user@example.com")
      account.add_project(project)
      AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: ActionType::NAME_MAP["Postgres:view"])
      account_with_no_access = Account.create(email: "user2@example.com")
      account_with_no_access.add_project(project)
      allow(Util).to receive(:send_email)
      server
    end

    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-canceled-email") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    it "sends email with canceled info including current storage and instance size" do
      postgres_resource.send_storage_auto_scale_canceled_notification

      expect(Util).to have_received(:send_email).with(
        ["user@example.com"],
        "PostgreSQL Auto-Scaling Canceled: pg-name",
        hash_including(
          greeting: "Hello,",
          body: array_including(/has been canceled as requested/)
        )
      )
    end
  end

  describe "#can_cancel_storage_auto_scale?" do
    it "returns false if canceled semaphore is already set or 90% action is not set" do
      # Neither set
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false

      # 90% set but canceled also set
      postgres_resource.incr_storage_auto_scale_action_performed_90
      postgres_resource.incr_storage_auto_scale_canceled
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false
    end

    it "returns false if no converge strand exists" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false
    end

    it "returns false if converge strand label is not in allowed list" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(
        prog: "Postgres::ConvergePostgresResource",
        label: "recycle_representative_server",
        parent_id: postgres_resource.strand.id
      )
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false
    end

    it "returns true when 90% action is set, not canceled, and converge strand is in an early label" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      %w[start provision_servers wait_servers_to_be_ready wait_for_maintenance_window].each do |label|
        Strand.dataset.where(prog: "Postgres::ConvergePostgresResource").destroy
        Strand.create(
          prog: "Postgres::ConvergePostgresResource",
          label:,
          parent_id: postgres_resource.strand.id
        )
        expect(postgres_resource.can_cancel_storage_auto_scale?).to be(true), "expected true for label #{label}"
      end
    end
  end

  describe "#cancel_storage_auto_scale" do
    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-cancel") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    before do
      VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
      server
      account = Account.create(email: "user@example.com")
      account.add_project(project)
      AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: ActionType::NAME_MAP["Postgres:view"])
      account_with_no_access = Account.create(email: "user2@example.com")
      account_with_no_access.add_project(project)
      allow(Util).to receive(:send_email)
    end

    it "returns false if advisory lock cannot be acquired" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "start", parent_id: postgres_resource.strand.id)

      expect(DB).to receive(:get).with(Sequel.function(:pg_try_advisory_xact_lock, postgres_resource.storage_auto_scale_lock_key)).and_return(false)
      expect(postgres_resource.cancel_storage_auto_scale).to be false
    end

    it "returns false if can_cancel_storage_auto_scale? is false" do
      # 90% action not set, so can_cancel returns false
      expect(postgres_resource.cancel_storage_auto_scale).to be false
    end

    it "resets targets, sets semaphore, creates page, sends email and returns true on success" do
      postgres_resource.update(target_vm_size: "standard-4", target_storage_size_gib: 256)
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "provision_servers", parent_id: postgres_resource.strand.id)

      result = postgres_resource.cancel_storage_auto_scale

      expect(result).to be true
      postgres_resource.reload
      expect(postgres_resource.target_vm_size).to eq("standard-2")
      expect(postgres_resource.target_storage_size_gib).to eq(64)
      expect(postgres_resource.storage_auto_scale_canceled_set?).to be true
      expect(Page.from_tag_parts("PGStorageAutoScaleCanceled", postgres_resource.id)).not_to be_nil
      expect(Util).to have_received(:send_email).with(
        ["user@example.com"],
        "PostgreSQL Auto-Scaling Canceled: pg-name",
        hash_including(greeting: "Hello,")
      )
    end

    it "also resets read replica targets on success" do
      read_replica = described_class.create(
        name: "pg-rr-cancel", superuser_password: "dummy", ha_type: "none",
        target_version: "17", location_id:, project_id: project.id, user_config: {},
        pgbouncer_user_config: {}, target_vm_size: "standard-4", target_storage_size_gib: 256,
        parent_id: postgres_resource.id
      )
      postgres_resource.update(target_vm_size: "standard-4", target_storage_size_gib: 256)
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "start", parent_id: postgres_resource.strand.id)

      postgres_resource.cancel_storage_auto_scale

      expect(read_replica.reload.target_vm_size).to eq("standard-2")
      expect(read_replica.reload.target_storage_size_gib).to eq(64)
    end
  end

  describe ".generate_postgres_options" do
    let(:gcp_location) {
      Location.create(name: "gcp-us-central1", provider: "gcp", display_name: "us-central1", ui_name: "Iowa, US (GCP)", visible: false)
    }

    it "allows GCP families for GCP locations" do
      option_tree, parents = described_class.generate_postgres_options(project, location: [gcp_location])
      allowed_families = OptionTreeGenerator.generate_allowed_options("family", option_tree, parents)
      family_names = allowed_families.map { it["family"] }.uniq

      Option::GCP_FAMILY_OPTIONS.each do |family|
        expect(family_names).to include(family)
      end

      expect(family_names).not_to include("standard")
      expect(family_names).not_to include("hobby")
      expect(family_names).not_to include("m8gd")
    end

    it "allows metal families for metal locations" do
      option_tree, parents = described_class.generate_postgres_options(project, location: [location])
      allowed_families = OptionTreeGenerator.generate_allowed_options("family", option_tree, parents)
      family_names = allowed_families.map { it["family"] }.uniq

      expect(family_names).to include("standard", "hobby")
      Option::GCP_FAMILY_OPTIONS.each do |family|
        expect(family_names).not_to include(family)
      end
    end

    it "provides fixed storage sizes for GCP families" do
      option_tree, parents = described_class.generate_postgres_options(project, location: [gcp_location])
      allowed_storage = OptionTreeGenerator.generate_allowed_options("storage_size", option_tree, parents)

      # Check c4a-standard-8: should have exactly 750 GiB (2 × 375)
      c4a_8_options = allowed_storage.select { it["size"] == "c4a-standard-8" }
      expect(c4a_8_options.map { it["storage_size"] }).to eq([750])

      # Check c3d-standard-30: should have exactly 750 GiB (2 × 375)
      c3d_30_options = allowed_storage.select { it["size"] == "c3d-standard-30" }
      expect(c3d_30_options.map { it["storage_size"] }).to eq([750])

      # Check c3-standard-176: should have exactly 12000 GiB (32 × 375)
      c3_176_options = allowed_storage.select { it["size"] == "c3-standard-176" }
      expect(c3_176_options.map { it["storage_size"] }).to eq([12000])
    end
  end
end
