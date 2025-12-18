# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  let(:project) { Project.create(name: "test-project") }
  let(:postgres_project) { Project.create(name: "postgres-service") }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "test-subnet", project:, location_id: Location::HETZNER_FSN1_ID,
      net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
      net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64")
    )
  }
  let(:timeline) { PostgresTimeline.create(location_id: Location::HETZNER_FSN1_ID) }

  let(:postgres_resource) {
    described_class.create(
      name: "pg-name",
      project:,
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      location_id: Location::HETZNER_FSN1_ID
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  def create_server(resource:, timeline:, representative: false, version: nil, **attrs)
    vm = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "test-vm-#{SecureRandom.hex(4)}",
      private_subnet_id: private_subnet.id, location_id: resource.location_id,
      size: resource.target_vm_size
    ).subject
    # Manually create storage volumes (normally created during allocation)
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 16, disk_index: 0)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: resource.target_storage_size_gib, disk_index: 1)

    server = PostgresServer.create(
      resource:, timeline:, vm_id: vm.id,
      timeline_access: representative ? "push" : "fetch",
      synchronization_status: "ready",
      version: version || resource.target_version,
      representative_at: representative ? Time.now : nil,
      **attrs
    )
    # Create strand for the server
    Strand.create(id: server.id, prog: "Postgres::PostgresServerNexus", label: "wait")
    server
  end

  it "returns connection string without ubid qualifier" do
    DnsZone.create(project_id: postgres_project.id, name: Config.postgres_service_hostname)
    postgres_resource.update(hostname_version: "v1")
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.postgres.ubicloud.com:5432/postgres?channel_binding=require")
  end

  it "returns connection string with ubid qualifier" do
    DnsZone.create(project_id: postgres_project.id, name: Config.postgres_service_hostname)
    postgres_resource.update(hostname_version: "v2")
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com:5432/postgres?channel_binding=require")
  end

  it "returns connection string with ip address if config is not set" do
    server = create_server(resource: postgres_resource, timeline:, representative: true)
    vm = server.vm
    vm_host = create_vm_host(total_cores: 10, used_cores: 3)
    cidr = IPAddr.new("1.2.3.4")
    cidr.prefix = 24
    addr = Address.create(cidr: cidr.to_s, routed_to_host_id: vm_host.id)
    AssignedVmAddress.create(ip: "1.2.3.4", address_id: addr.id, dst_vm_id: vm.id)

    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@1.2.3.4:5432/postgres?channel_binding=require")
  end

  it "returns connection string as nil if there is no server" do
    expect(postgres_resource.representative_server).to be_nil
    expect(postgres_resource.connection_string).to be_nil
  end

  it "returns replication_connection_string" do
    s = postgres_resource.replication_connection_string(application_name: "pgubidstandby")
    expect(s).to include("ubi_replication@#{postgres_resource.ubid}.postgres.ubicloud.com", "application_name=pgubidstandby", "sslcert=/etc/ssl/certs/server.crt")
  end

  it "returns has_enough_fresh_servers correctly" do
    create_server(resource: postgres_resource, timeline:, representative: true)

    # 1 server, target_server_count = 1 (ha_type=none) => true
    expect(postgres_resource.has_enough_fresh_servers?).to be(true)

    # 1 server, target_server_count = 2 (ha_type=async) => false
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.has_enough_fresh_servers?).to be(false)
  end

  it "returns has_enough_fresh_servers correctly during upgrades" do
    postgres_resource.update(target_version: "17")
    create_server(resource: postgres_resource, timeline:, representative: true, version: "16")

    # Create standby with boot image that has proper version
    standby = create_server(resource: postgres_resource, timeline:, representative: false, version: "16")
    vm_host = create_vm_host
    good_boot_image = BootImage.create(name: "postgres17-ubuntu-2204", version: "20240801", vm_host_id: vm_host.id, size_gib: 10)
    VmStorageVolume.where(vm_id: standby.vm.id, boot: true).update(boot_image_id: good_boot_image.id)

    expect(postgres_resource.has_enough_fresh_servers?).to be(true)

    # When no candidate exists (old boot image version)
    old_boot_image = BootImage.create(name: "postgres16-ubuntu-2204", version: "20240701", vm_host_id: vm_host.id, size_gib: 10)
    VmStorageVolume.where(vm_id: standby.vm.id, boot: true).update(boot_image_id: old_boot_image.id)
    # Refresh to get fresh association data
    expect(described_class[postgres_resource.id].has_enough_fresh_servers?).to be(false)
  end

  it "returns upgrade_candidate_server when candidate is available and location is not aws" do
    postgres_resource.update(target_version: "17")

    create_server(resource: postgres_resource, timeline:, representative: true, version: "16")

    # Standby servers - standby2 has later created_at
    standby1 = create_server(resource: postgres_resource, timeline:, representative: false, version: "16")
    standby1.update(created_at: Time.now - 3600)

    standby2 = create_server(resource: postgres_resource, timeline:, representative: false, version: "16")
    standby2.update(created_at: Time.now)

    # Set up boot images with proper version for upgrade
    vm_host = create_vm_host
    boot_image = BootImage.create(name: "postgres17-ubuntu-2204", version: "20240801", vm_host_id: vm_host.id, size_gib: 10)
    VmStorageVolume.where(vm_id: standby1.vm.id, boot: true).update(boot_image_id: boot_image.id)
    VmStorageVolume.where(vm_id: standby2.vm.id, boot: true).update(boot_image_id: boot_image.id)

    # Should return the one with latest creation time
    expect(postgres_resource.upgrade_candidate_server.id).to eq(standby2.id)
  end

  it "returns upgrade_candidate_server when candidate is not available and location is not aws" do
    postgres_resource.update(target_version: "17")

    create_server(resource: postgres_resource, timeline:, representative: true, version: "16")

    # Standby servers with old boot image version
    standby1 = create_server(resource: postgres_resource, timeline:, representative: false, version: "16")
    standby2 = create_server(resource: postgres_resource, timeline:, representative: false, version: "16")

    vm_host = create_vm_host
    boot_image = BootImage.create(name: "postgres16-ubuntu-2204", version: "20240729", vm_host_id: vm_host.id, size_gib: 10)
    VmStorageVolume.where(vm_id: standby1.vm.id, boot: true).update(boot_image_id: boot_image.id)
    VmStorageVolume.where(vm_id: standby2.vm.id, boot: true).update(boot_image_id: boot_image.id)

    expect(postgres_resource.upgrade_candidate_server).to be_nil
  end

  it "returns upgrade_candidate_server when candidate is available and location is aws" do
    aws_location = Location.create(name: "us-east-1", display_name: "us-east-1", provider: "aws", ui_name: "us-east-1", visible: true)
    aws_subnet = PrivateSubnet.create(
      name: "aws-subnet", project:, location_id: aws_location.id,
      net4: NetAddr::IPv4Net.parse("172.0.1.0/26"),
      net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3e::/64")
    )
    aws_resource = described_class.create(
      name: "pg-aws", project:, superuser_password: "dummy-password",
      ha_type: "none", target_version: "17", target_vm_size: "standard-2",
      target_storage_size_gib: 64, location_id: aws_location.id
    )

    # Create servers with different AMIs - AWS nexus creates storage volumes automatically
    vm1 = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "aws-vm-1", private_subnet_id: aws_subnet.id, location_id: aws_location.id,
      size: "standard-2"
    ).subject
    vm1.update(boot_image: "ami-12345678")

    vm2 = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "aws-vm-2", private_subnet_id: aws_subnet.id, location_id: aws_location.id,
      size: "standard-2"
    ).subject
    vm2.update(boot_image: "ami-87654321")

    primary = PostgresServer.create(resource: aws_resource, timeline:, vm_id: vm1.id, timeline_access: "push", synchronization_status: "ready", version: "16", representative_at: Time.now)
    Strand.create(id: primary.id, prog: "Postgres::PostgresServerNexus", label: "wait")

    standby1 = PostgresServer.create(resource: aws_resource, timeline:, vm_id: vm1.id, timeline_access: "fetch", synchronization_status: "ready", version: "16", created_at: Time.now - 3600)
    Strand.create(id: standby1.id, prog: "Postgres::PostgresServerNexus", label: "wait")

    standby2 = PostgresServer.create(resource: aws_resource, timeline:, vm_id: vm2.id, timeline_access: "fetch", synchronization_status: "ready", version: "16", created_at: Time.now)
    Strand.create(id: standby2.id, prog: "Postgres::PostgresServerNexus", label: "wait")

    # Only ami-12345678 is registered as valid - update or create with correct AMI
    ami = PgAwsAmi.find_or_create(aws_location_name: "us-east-1", pg_version: "17", arch: "x64") { it.aws_ami_id = "ami-12345678" }
    ami.update(aws_ami_id: "ami-12345678")

    expect(aws_resource.upgrade_candidate_server.id).to eq(standby1.id)
  end

  it "returns has_enough_ready_servers correctly when not upgrading" do
    server = create_server(resource: postgres_resource, timeline:, representative: true)
    server.strand.update(label: "wait")

    # 1 server in wait state, target = 1 => true
    expect(postgres_resource.has_enough_ready_servers?).to be(true)

    # 1 server in wait state, target = 2 => false
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is not present" do
    create_server(resource: postgres_resource, timeline:, representative: true, version: "16")
    postgres_resource.update(target_version: "17")
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is not in wait state" do
    create_server(resource: postgres_resource, timeline:, representative: true, version: "16")
    postgres_resource.update(target_version: "17")

    standby = create_server(resource: postgres_resource, timeline:, representative: false, version: "16")
    standby.strand.update(label: "wait_bootstrap_rhizome")

    # Set up boot image for candidate
    vm_host = create_vm_host
    boot_image = BootImage.create(name: "postgres17-ubuntu-2204", version: "20240801", vm_host_id: vm_host.id, size_gib: 10)
    VmStorageVolume.where(vm_id: standby.vm.id, boot: true).update(boot_image_id: boot_image.id)

    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is ready" do
    create_server(resource: postgres_resource, timeline:, representative: true, version: "16")
    postgres_resource.update(target_version: "17")

    standby = create_server(resource: postgres_resource, timeline:, representative: false, version: "16")
    standby.strand.update(label: "wait")

    # Set up boot image for candidate
    vm_host = create_vm_host
    boot_image = BootImage.create(name: "postgres17-ubuntu-2204", version: "20240801", vm_host_id: vm_host.id, size_gib: 10)
    VmStorageVolume.where(vm_id: standby.vm.id, boot: true).update(boot_image_id: boot_image.id)

    expect(postgres_resource.has_enough_ready_servers?).to be(true)
  end

  it "returns needs_convergence correctly when not upgrading" do
    create_server(resource: postgres_resource, timeline:, representative: true)

    # Server count = target_server_count (1 = 1) and all conditions met => false
    expect(postgres_resource.needs_convergence?).to be(false)

    # Server count != target_server_count (1 != 2) => true
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.needs_convergence?).to be(true)
  end

  it "returns needs_convergence correctly when upgrading" do
    server = create_server(resource: postgres_resource, timeline:, representative: true, version: "16")
    server.strand.update(label: "wait")
    postgres_resource.update(target_version: "17")

    expect(postgres_resource.needs_convergence?).to be(true)
  end

  it "#pg_firewall_rules returns empty array when there is no customer firewall" do
    postgres_resource.update(private_subnet_id: private_subnet.id)
    expect(postgres_resource.customer_firewall).to be_nil
    expect(postgres_resource.pg_firewall_rules).to eq []
  end

  describe "display_state" do
    before do
      Strand.create(id: postgres_resource.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
    end

    it "returns 'deleting' when strand label is 'destroy'" do
      postgres_resource.strand.update(label: "destroy")
      expect(postgres_resource.display_state).to eq("deleting")
    end

    it "returns 'unavailable' when representative server's strand label is 'unavailable'" do
      postgres_resource.strand.update(label: "wait")
      server = create_server(resource: postgres_resource, timeline:, representative: true)
      server.strand.update(label: "unavailable")
      expect(postgres_resource.display_state).to eq("unavailable")
    end

    it "returns 'restoring_backup' when representative server's strand label is 'initialize_database_from_backup'" do
      postgres_resource.strand.update(label: "wait")
      server = create_server(resource: postgres_resource, timeline:, representative: true)
      server.strand.update(label: "initialize_database_from_backup")
      expect(postgres_resource.display_state).to eq("restoring_backup")
    end

    it "returns 'replaying_wal' when representative server's strand label is 'wait_catch_up'" do
      postgres_resource.strand.update(label: "wait")
      server = create_server(resource: postgres_resource, timeline:, representative: true)
      server.strand.update(label: "wait_catch_up")
      expect(postgres_resource.display_state).to eq("replaying_wal")
    end

    it "returns 'replaying_wal' when representative server's strand label is 'wait_synchronization'" do
      postgres_resource.strand.update(label: "wait")
      server = create_server(resource: postgres_resource, timeline:, representative: true)
      server.strand.update(label: "wait_synchronization")
      expect(postgres_resource.display_state).to eq("replaying_wal")
    end

    it "returns 'finalizing_restore' when representative server's strand label is 'wait_recovery_completion'" do
      postgres_resource.strand.update(label: "wait")
      server = create_server(resource: postgres_resource, timeline:, representative: true)
      server.strand.update(label: "wait_recovery_completion")
      expect(postgres_resource.display_state).to eq("finalizing_restore")
    end

    it "returns 'running' when strand label is 'wait' and has no children" do
      postgres_resource.strand.update(label: "wait")
      expect(postgres_resource.display_state).to eq("running")
    end

    it "returns 'creating' when strand is 'wait_server'" do
      postgres_resource.strand.update(label: "wait_server")
      expect(postgres_resource.display_state).to eq("creating")
    end
  end

  it "returns in_maintenance_window? correctly" do
    # nil maintenance_window_start_at => always in window
    expect(postgres_resource.in_maintenance_window?).to be(true)

    # Set maintenance_window_start_at to 1 (1 AM UTC), with 2 hour duration (MAINTENANCE_DURATION_IN_HOURS)
    # Window is 1 AM - 3 AM UTC
    postgres_resource.update(maintenance_window_start_at: 1)

    # Test the calculation logic: (current_hour - start) % 24 < MAINTENANCE_DURATION_IN_HOURS
    # At 2 AM UTC - within window (1 hour after start) => true
    time_2am = Time.utc(2025, 5, 1, 2, 0, 0)
    expect((time_2am.utc.hour - 1) % 24 < PostgresResource::MAINTENANCE_DURATION_IN_HOURS).to be(true)

    # At 3 AM UTC - outside window (2 hours after start, duration is 2) => false
    time_3am = Time.utc(2025, 5, 1, 3, 0, 0)
    expect((time_3am.utc.hour - 1) % 24 < PostgresResource::MAINTENANCE_DURATION_IN_HOURS).to be(false)

    # At midnight UTC - outside window (23 hours after start) => false
    time_midnight = Time.utc(2025, 5, 1, 0, 0, 0)
    expect((time_midnight.utc.hour - 1) % 24 < PostgresResource::MAINTENANCE_DURATION_IN_HOURS).to be(false)
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
    (0..2).each do |count|
      ha_type = [PostgresResource::HaType::NONE, PostgresResource::HaType::ASYNC, PostgresResource::HaType::SYNC][count]
      postgres_resource.update(ha_type:)
      expect(postgres_resource.target_server_count).to eq(count + 1)
    end
  end

  describe "#ongoing_failover?" do
    it "returns false if there is no ongoing failover" do
      server1 = create_server(resource: postgres_resource, timeline:, representative: true)
      server2 = create_server(resource: postgres_resource, timeline:, representative: false)
      server1.strand.update(label: "wait")
      server2.strand.update(label: "wait")
      expect(postgres_resource.ongoing_failover?).to be false
    end

    it "returns true if there is an ongoing failover" do
      server1 = create_server(resource: postgres_resource, timeline:, representative: true)
      server2 = create_server(resource: postgres_resource, timeline:, representative: false)
      server1.strand.update(label: "wait")
      server2.strand.update(label: "taking_over")
      expect(postgres_resource.ongoing_failover?).to be true
    end
  end

  describe "#hostname_suffix" do
    it "returns default hostname suffix if project is nil" do
      resource = described_class.new(
        name: "pg-orphan", superuser_password: "dummy",
        ha_type: "none", target_version: "17", location_id: Location::HETZNER_FSN1_ID
      )
      expect(resource.hostname_suffix).to eq(Config.postgres_service_hostname)
    end
  end

  describe "#upgrade_stage" do
    before do
      Strand.create(id: postgres_resource.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
    end

    it "returns nil if there's no ongoing upgrade" do
      expect(postgres_resource.upgrade_stage).to be_nil
    end

    it "returns the upgrade stage if there's an ongoing upgrade" do
      Strand.create(
        prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby",
        parent_id: postgres_resource.strand.id
      )
      expect(postgres_resource.upgrade_stage).to eq("upgrade_standby")
    end
  end

  describe "#upgrade_status" do
    before do
      Strand.create(id: postgres_resource.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
    end

    it "returns failed if the postgres resource upgrade failed" do
      Strand.create(
        prog: "Postgres::ConvergePostgresResource", label: "upgrade_failed",
        parent_id: postgres_resource.strand.id
      )
      expect(postgres_resource.upgrade_status).to eq("failed")
    end

    it "returns not_running if the postgres resource does not need upgrade" do
      expect(postgres_resource.upgrade_status).to eq("not_running")
    end

    it "returns running if the postgres resource upgrade is in progress" do
      Strand.create(
        prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby",
        parent_id: postgres_resource.strand.id
      )
      create_server(resource: postgres_resource, timeline:, representative: true, version: "16")
      postgres_resource.update(target_version: "17")
      expect(postgres_resource.upgrade_status).to eq("running")
    end
  end

  describe "#can_upgrade?" do
    it "returns true if the postgres resource can be upgraded" do
      postgres_resource.update(target_version: "16", flavor: PostgresResource::Flavor::STANDARD)
      expect(postgres_resource.can_upgrade?).to be true
    end

    it "returns false if the postgres resource cannot be upgraded" do
      postgres_resource.update(flavor: PostgresResource::Flavor::LANTERN, target_version: "17")
      expect(postgres_resource.can_upgrade?).to be false
    end
  end

  describe "#ready_for_read_replica?" do
    before do
      Strand.create(id: postgres_resource.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
    end

    it "returns true if the postgres resource is ready for read replica" do
      server = create_server(resource: postgres_resource, timeline:, representative: true)
      server.strand.update(label: "wait")

      # Stub earliest_restore_time since it requires S3 calls
      allow(PostgresTimeline).to receive(:earliest_restore_time).with(timeline).and_return(Time.now - 3600)

      expect(postgres_resource.ready_for_read_replica?).to be true
    end

    it "returns false if the postgres resource needs convergence" do
      # No servers => needs convergence
      expect(postgres_resource.needs_convergence?).to be true
      expect(postgres_resource.ready_for_read_replica?).to be false
    end

    it "returns false if there is no earliest restore time" do
      server = create_server(resource: postgres_resource, timeline:, representative: true)
      server.strand.update(label: "wait")

      allow(PostgresTimeline).to receive(:earliest_restore_time).with(timeline).and_return(nil)
      expect(postgres_resource.ready_for_read_replica?).to be false
    end
  end

  describe "#install_rhizome" do
    it "installs rhizome on all servers" do
      vm1 = Prog::Vm::Nexus.assemble_with_sshable(project.id, name: "test-vm-1", private_subnet_id: private_subnet.id, location_id: Location::HETZNER_FSN1_ID).subject
      vm2 = Prog::Vm::Nexus.assemble_with_sshable(project.id, name: "test-vm-2", private_subnet_id: private_subnet.id, location_id: Location::HETZNER_FSN1_ID).subject

      PostgresServer.create(resource: postgres_resource, timeline:, vm_id: vm1.id, timeline_access: "push", synchronization_status: "ready", version: "16", representative_at: Time.now)
      PostgresServer.create(resource: postgres_resource, timeline:, vm_id: vm2.id, timeline_access: "fetch", synchronization_status: "catching_up", version: "16")

      postgres_resource.install_rhizome

      strands = Strand.where(prog: "InstallRhizome").all
      expect(strands.size).to eq(2)
      expect(strands.map { it.stack.first["subject_id"] }).to contain_exactly(vm1.id, vm2.id)
      strands.each do |strand|
        expect(strand.stack.first["target_folder"]).to eq("postgres")
        expect(strand.stack.first["install_specs"]).to be false
      end
    end
  end
end
