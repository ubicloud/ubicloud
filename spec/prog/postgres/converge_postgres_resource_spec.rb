# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::ConvergePostgresResource do
  subject(:nx) { described_class.new(strand) }

  let(:postgres_service_project) { Project.create(name: "postgres-service-project") }
  let(:project) { Project.create(name: "converge-test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:location) { Location[location_id] }
  let(:timeline) { create_postgres_timeline(location_id:) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }

  let(:pg) {
    pr = create_postgres_resource(project:, location_id:)
    Firewall.create(name: "#{pr.ubid}-internal-firewall", location_id:, project_id: postgres_service_project.id)
    pr
  }

  let(:strand) {
    Strand.create(
      prog: "Postgres::ConvergePostgresResource", label: "start",
      parent_id: pg.strand.id,
      stack: [{"subject_id" => pg.id}],
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_service_project.id)
  end

  def create_server(vm_host_data_center: "default-dc", timeline: self.timeline, resource: pg, is_representative: false, version: nil, subnet_az: nil, zone_suffix: nil, upgrade_candidate: false)
    server = create_postgres_server(resource:, timeline:, is_representative:)
    server.strand.update(label: "wait")
    server.update(version:) if version
    vm = server.vm

    if vm_host_data_center
      vm_host = create_vm_host(location_id: resource.location_id, data_center: vm_host_data_center)
      vm.update(vm_host_id: vm_host.id)
    end

    if subnet_az
      NicAwsResource.create_with_id(vm.nic.id, subnet_az:)
    end

    if zone_suffix
      location_az = LocationAz.first(location_id: resource.location_id, az: zone_suffix) ||
        LocationAz.create(location_id: resource.location_id, az: zone_suffix)
      VmGcpResource.create_with_id(vm, location_az_id: location_az.id)
    end

    if upgrade_candidate
      unless vm.vm_host_id
        vm_host = create_vm_host(location_id: resource.location_id)
        vm.update(vm_host_id: vm_host.id)
      end
      boot_image = BootImage.create(vm_host_id: vm.vm_host_id, name: "ubuntu-jammy", version: "20240801", size_gib: 10)
      vm.vm_storage_volumes_dataset.where(disk_index: 0).update(boot_image_id: boot_image.id)
    end

    server
  end

  describe "#start" do
    it "naps if read replica parent is not ready" do
      parent = create_postgres_resource(project:, location_id:)
      create_server(resource: parent, is_representative: true)
      pg.update(parent_id: parent.id)

      expect { nx.start }.to nap(60)
    end

    it "registers a deadline and hops to provision_servers if read replica parent is ready" do
      parent_timeline = create_postgres_timeline(location_id:).tap { it.update(cached_earliest_backup_at: Time.now) }
      parent = create_postgres_resource(project:, location_id:)
      create_server(timeline: parent_timeline, is_representative: true, resource: parent)
      pg.update(parent_id: parent.id)

      expect(nx).to receive(:register_deadline).with("wait_for_maintenance_window", 10 * 60)
      expect { nx.start }.to hop("provision_servers")
    end
  end

  describe "#provision_servers" do
    before do
      strand.update(label: "provision_servers")
    end

    it "hops to wait_servers_to_be_ready if there are enough fresh servers" do
      create_server(is_representative: true, vm_host_data_center: "dc1")
      expect { nx.provision_servers }.to hop("wait_servers_to_be_ready")
    end

    it "does not provision a new server if there is a server that is not assigned to a vm_host" do
      server = create_server(is_representative: true, vm_host_data_center: "dc1")
      server.incr_recycle
      server.vm.update(vm_host_id: nil)
      expect { nx.provision_servers }.to nap.and not_change(PostgresServer, :count)
    end

    it "provisions a new server without excluding hosts when Config.allow_unspread_servers is true" do
      server = create_server(is_representative: true, vm_host_data_center: "dc1")
      server.incr_recycle
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      expect { nx.provision_servers }.to nap.and change(PostgresServer, :count).by(1)
    end

    it "provisions a new server but excludes currently used data centers" do
      server = create_server(is_representative: true, vm_host_data_center: "dc1")
      server.incr_recycle
      allow(Config).to receive(:allow_unspread_servers).and_return(false)
      expect { nx.provision_servers }.to nap.and change(PostgresServer, :count).by(1)
    end

    it "does not exclude AZs of recycling servers for aws" do
      location.update(provider: HostProvider::AWS_PROVIDER_NAME)
      LocationAz.create(location_id: location.id, az: "a", zone_id: "az1")
      LocationAz.create(location_id: location.id, az: "b", zone_id: "az2")
      PgAwsAmi.create(aws_location_name: location.name, pg_version: "17", arch: "x64", aws_ami_id: "ami-test")
      server1 = create_server(is_representative: true, subnet_az: "a")
      server2 = create_server(subnet_az: "b")
      server1.incr_recycle
      server2.incr_recycle
      pg.incr_use_different_az
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_availability_zones: [])).and_call_original
      expect { nx.provision_servers }.to nap.and change(PostgresServer, :count).by(1)
    end

    it "provisions a new server in a used az for aws if use_different_az_set? is false" do
      location.update(provider: HostProvider::AWS_PROVIDER_NAME)
      LocationAz.create(location_id: location.id, az: "a", zone_id: "az1")
      PgAwsAmi.create(aws_location_name: location.name, pg_version: "17", arch: "x64", aws_ami_id: "ami-test")
      server = create_server(is_representative: true, subnet_az: "a")
      server.incr_recycle
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(availability_zone: "a")).and_call_original
      expect { nx.provision_servers }.to nap.and change(PostgresServer, :count).by(1)
    end

    it "provisions a new server with the correct timeline for a regular instance" do
      server = create_server(is_representative: true, vm_host_data_center: "dc1")
      server.incr_recycle
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      expect { nx.provision_servers }.to nap
      expect(PostgresServer.order(:created_at).last.timeline_id).to eq(timeline.id)
    end

    it "provisions a new server with the correct timeline for a read replica" do
      parent_timeline = create_postgres_timeline(location_id:)
      parent = create_postgres_resource(project:, location_id:)
      create_server(timeline: parent_timeline, is_representative: true, resource: parent)
      pg.update(parent_id: parent.id)
      server = create_server(is_representative: true, vm_host_data_center: "dc1")
      server.incr_recycle
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      expect { nx.provision_servers }.to nap
      expect(PostgresServer.order(:created_at).last.timeline_id).to eq(parent_timeline.id)
    end

    it "provisions a new server on AWS even if a server is not assigned to a vm_host" do
      location.update(provider: HostProvider::AWS_PROVIDER_NAME)
      LocationAz.create(location_id: location.id, az: "a", zone_id: "fsn1-az1")
      PgAwsAmi.create(aws_location_name: location.name, pg_version: "17", arch: "x64", aws_ami_id: "ami-test")
      server = create_server(is_representative: true, subnet_az: "a")
      server.incr_recycle
      server.vm.update(vm_host_id: nil)
      expect { nx.provision_servers }.to nap.and change(PostgresServer, :count).by(1)
    end

    it "provisions a new server on GCP even if a server is not assigned to a vm_host" do
      location.update(provider: "gcp")
      LocationCredentialGcp.create_with_id(location,
        project_id: "test-project",
        service_account_email: "test@test.iam.gserviceaccount.com",
        credentials_json: "{}")
      PgGceImage.where(arch: "x64").each(&:destroy)
      PgGceImage.create(arch: "x64", gce_image_name: "postgres-x64-test", pg_versions: ["16", "17", "18"])
      server = create_server(is_representative: true, zone_suffix: "a")
      server.incr_recycle
      server.vm.update(vm_host_id: nil)
      expect { nx.provision_servers }.to nap.and change(PostgresServer, :count).from(1).to(2)
    end

    it "fails fast on GCP upgrade when no dual-version image is available" do
      location.update(provider: "gcp")
      LocationCredentialGcp.create_with_id(location,
        project_id: "test-project",
        service_account_email: "test@test.iam.gserviceaccount.com",
        credentials_json: "{}")
      PgGceImage.where(arch: "x64").each(&:destroy)
      PgGceImage.create(arch: "x64", gce_image_name: "pg-17-x64-a", pg_versions: ["17"])
      PgGceImage.create(arch: "x64", gce_image_name: "pg-18-x64-b", pg_versions: ["18"])
      create_server(is_representative: true, version: "17", zone_suffix: "a")
      pg.update(target_version: "18")

      expect {
        nx.provision_servers
      }.to raise_error(
        RuntimeError,
        /No dual-version GCE image found for arch x64 covering pg_version=17 \+ target_version=18/,
      ).and not_change(PostgresServer, :count)
    end

    it "provisions a GCP upgrade standby on the dual-version image when one exists" do
      location.update(provider: "gcp")
      LocationCredentialGcp.create_with_id(location,
        project_id: "test-project",
        service_account_email: "test@test.iam.gserviceaccount.com",
        credentials_json: "{}")
      expect(Config).to receive(:postgres_gce_image_gcp_project_id).and_return("image-hosting-project")
      PgGceImage.where(arch: "x64").each(&:destroy)
      PgGceImage.create(arch: "x64", gce_image_name: "pg-16-17-18-x64", pg_versions: ["16", "17", "18"])
      PgGceImage.create(arch: "x64", gce_image_name: "pg-18-19-x64", pg_versions: ["18", "19"])
      create_server(is_representative: true, version: "17", zone_suffix: "a")
      pg.update(target_version: "18")

      expect { nx.provision_servers }.to nap.and change(PostgresServer, :count).from(1).to(2)
      new_standby = PostgresServer.where(is_representative: false).first
      expect(new_standby.vm.boot_image).to eq(
        "projects/image-hosting-project/global/images/pg-16-17-18-x64",
      )
      expect(new_standby.version).to eq("17")
    end
  end

  describe "#wait_servers_to_be_ready" do
    before do
      strand.update(label: "wait_servers_to_be_ready")
    end

    it "hops to provision_servers if there is not enough fresh servers" do
      server = create_server(is_representative: true)
      server.incr_recycle
      expect { nx.wait_servers_to_be_ready }.to hop("provision_servers")
    end

    it "hops to wait_for_maintenance_window if there are enough ready servers" do
      create_server(is_representative: true)
      expect { nx.wait_servers_to_be_ready }.to hop("wait_for_maintenance_window")
    end

    it "waits and extends deadline if disk usage increased" do
      pg.update(ha_type: "async")
      create_server(is_representative: true)
      standby = create_server
      standby.strand.update(label: "wait_catch_up")
      standby_from_assoc = nx.postgres_resource.servers.find { !it.is_representative }
      expect(standby_from_assoc).to receive(:data_disk_usage).and_return(1024000)
      standby.update_last_known_lsn("0/0")
      expect { nx.wait_servers_to_be_ready }.to nap
      expect(strand.reload.stack.first["total_disk_usage"]).to eq(1024000)
    end

    it "waits and extends deadline if lsn advanced" do
      pg.update(ha_type: "async")
      create_server(is_representative: true)
      standby = create_server
      standby.strand.update(label: "wait_catch_up")
      standby_from_assoc = nx.postgres_resource.servers.find { !it.is_representative }
      expect(standby_from_assoc).to receive(:data_disk_usage).and_return(1024000)
      standby.update_last_known_lsn("0/1234567")
      strand.stack.first["total_disk_usage"] = 2048000
      strand.modified!(:stack)
      strand.save_changes
      expect { nx.wait_servers_to_be_ready }.to nap
      expect(strand.reload.stack.first["total_lsn"]).to eq(standby.lsn2int("0/1234567"))
      expect(strand.reload.stack.first["total_disk_usage"]).to eq(2048000)
    end

    it "waits without extending deadline if neither disk usage nor lsn increased" do
      pg.update(ha_type: "async")
      create_server(is_representative: true)
      standby = create_server
      standby.strand.update(label: "wait_catch_up")
      standby_from_assoc = nx.postgres_resource.servers.find { !it.is_representative }
      expect(standby_from_assoc).to receive(:data_disk_usage).and_return(1024000)
      standby.update_last_known_lsn("0/1234567")
      strand.stack.first["total_disk_usage"] = 2048000
      strand.stack.first["total_lsn"] = standby.lsn2int("0/FFFFFFF")
      strand.modified!(:stack)
      strand.save_changes
      expect(nx).not_to receive(:register_deadline)
      expect { nx.wait_servers_to_be_ready }.to nap
    end

    it "treats last_known_lsn as zero when it is nil" do
      pg.update(ha_type: "async")
      create_server(is_representative: true)
      standby = create_server
      standby.strand.update(label: "wait_catch_up")
      standby_from_assoc = nx.postgres_resource.servers.find { !it.is_representative }
      expect(standby_from_assoc).to receive(:data_disk_usage).and_return(0)
      expect(nx).not_to receive(:register_deadline)
      expect { nx.wait_servers_to_be_ready }.to nap
    end

    it "sums disk usage and lsn across multiple standbys" do
      pg.update(ha_type: "async")
      create_server(is_representative: true)
      standby1 = create_server
      standby1.strand.update(label: "wait_catch_up")
      standby2 = create_server
      standby2.strand.update(label: "wait_catch_up")

      standby1.update_last_known_lsn("0/100")
      standby2.update_last_known_lsn("0/200")

      servers = nx.postgres_resource.servers
      expect(servers.reject { it.is_representative }).to all(receive(:data_disk_usage).and_return(512000))

      expect { nx.wait_servers_to_be_ready }.to nap
      expect(strand.reload.stack.first["total_disk_usage"]).to eq(1024000)
      expect(strand.reload.stack.first["total_lsn"]).to eq(standby1.lsn2int("0/100") + standby2.lsn2int("0/200"))
    end

    it "ignores recycling standbys when checking progress" do
      pg.update(ha_type: "async")
      create_server(is_representative: true)
      recycling_standby = create_server
      recycling_standby.incr_recycle
      fresh_standby = create_server
      fresh_standby.strand.update(label: "wait_catch_up")
      servers = nx.postgres_resource.servers
      recycling_from_assoc = servers.find { it.id == recycling_standby.id }
      fresh_from_assoc = servers.find { it.id == fresh_standby.id }
      expect(recycling_from_assoc).not_to receive(:data_disk_usage)
      recycling_standby.update_last_known_lsn("0/FFFFFFF")
      expect(fresh_from_assoc).to receive(:data_disk_usage).and_return(1024000)
      fresh_standby.update_last_known_lsn("0/0")
      expect { nx.wait_servers_to_be_ready }.to nap
      expect(strand.reload.stack.first["total_disk_usage"]).to eq(1024000)
    end
  end

  describe "#recycle_representative_server" do
    before do
      strand.update(label: "recycle_representative_server")
    end

    it "naps if there is an ongoing failover" do
      server = create_server(is_representative: true)
      server.incr_recycle
      server.incr_planned_take_over
      expect { nx.recycle_representative_server }.to nap(60)
    end

    it "hops to prune_servers if the representative server does not need recycling" do
      create_server(is_representative: true)
      expect { nx.recycle_representative_server }.to hop("prune_servers")
    end

    it "hops to provision_servers if there are not enough ready servers" do
      server = create_server(is_representative: true)
      server.incr_recycle
      expect { nx.recycle_representative_server }.to hop("provision_servers")
    end

    it "hops to prune_servers if storage auto-scale was canceled" do
      server = create_server(is_representative: true)
      server.incr_recycle
      create_server(is_representative: false)
      pg.incr_storage_auto_scale_canceled
      expect { nx.recycle_representative_server }.to hop("prune_servers")
    end

    it "naps if advisory lock cannot be acquired before failover" do
      server = create_server(is_representative: true)
      server.incr_recycle
      create_server(is_representative: false)
      expect(DB).to receive(:get).with(Sequel.function(:pg_try_advisory_xact_lock, pg.storage_auto_scale_lock_key)).and_return(false)
      expect { nx.recycle_representative_server }.to nap(5)
    end

    it "does not increment storage_auto_scale_not_cancellable redundantly" do
      server = create_server(is_representative: true)
      server.incr_recycle
      create_server(is_representative: false)
      expect { nx.recycle_representative_server }.to nap(60)
      nx.postgres_resource.reload # break semaphores cache
      expect { nx.recycle_representative_server }.to nap(60)
      expect(nx.postgres_resource.reload.semaphores.count { it.name == "storage_auto_scale_not_cancellable" }).to eq(1)
    end

    it "triggers failover when representative needs recycling and standby is ready" do
      server = create_server(is_representative: true)
      server.incr_recycle
      standby = create_server(is_representative: false)
      standby.update(physical_slot_ready_id: server.id)
      standby_from_assoc = nx.postgres_resource.servers.find { !it.is_representative }
      expect(standby_from_assoc.vm.sshable).to receive(:_cmd).and_return("0/1234567")
      representative = nx.postgres_resource.representative_server
      expect(representative.vm.sshable).to receive(:_cmd).and_return("")
      expect { nx.recycle_representative_server }.to nap(60)
      expect(standby.reload.planned_take_over_set?).to be true
    end
  end

  describe "#wait_for_maintenance_window" do
    before do
      strand.update(label: "wait_for_maintenance_window")
      pg.update(maintenance_window_start_at: nil)
    end

    it "hops to provision_servers if there are not enough fresh servers" do
      server = create_server(is_representative: true)
      server.incr_recycle
      expect { nx.wait_for_maintenance_window }.to hop("provision_servers")
    end

    it "hops to recycle_representative_server if in maintenance window and not upgrading" do
      create_server(is_representative: true)
      expect { nx.wait_for_maintenance_window }.to hop("recycle_representative_server")
    end

    it "fences primary and hops to wait_fence_primary if in maintenance window and upgrading" do
      server = create_server(is_representative: true, version: "16")
      candidate = create_server(version: "16", upgrade_candidate: true)
      expect(nx.postgres_resource.representative_server).to receive(:unsynced_logical_failover_slots).with(candidate).and_return([])
      expect { nx.wait_for_maintenance_window }.to hop("wait_fence_primary")
      expect(server.reload.fence_set?).to be true
    end

    it "naps without fencing when upgrade candidate has unsynced logical failover slots" do
      server = create_server(is_representative: true, version: "16")
      candidate = create_server(version: "16", upgrade_candidate: true)
      expect(nx.postgres_resource.representative_server).to receive(:unsynced_logical_failover_slots).with(candidate).and_return(["slot1"])
      expect(Clog).to receive(:emit).with("Upgrade waiting for logical slot sync", hash_including(missing_slots: ["slot1"]))
      expect { nx.wait_for_maintenance_window }.to nap(30)
      expect(server.reload.fence_set?).to be false
    end

    it "hops to recycle_representative_server if in maintenance window and upgrading for read replicas" do
      parent = create_postgres_resource(project:, location_id:)
      pg.update(parent_id: parent.id)
      create_server(is_representative: true, version: "16")
      create_server(version: "16", upgrade_candidate: true)

      expect { nx.wait_for_maintenance_window }.to hop("recycle_representative_server")
    end

    it "waits if not in maintenance window" do
      pg.update(maintenance_window_start_at: (Time.now.utc.hour + 12) % 24)
      expect { nx.wait_for_maintenance_window }.to nap(10 * 60)
    end
  end

  describe "#wait_fence_primary" do
    before do
      strand.update(label: "wait_fence_primary")
    end

    it "hops to upgrade_standby when primary is fenced" do
      server = create_server(is_representative: true)
      server.strand.update(label: "wait_in_fence")
      expect { nx.wait_fence_primary }.to hop("upgrade_standby")
    end

    it "waits when primary is not yet fenced" do
      create_server(is_representative: true)
      expect { nx.wait_fence_primary }.to nap(5)
    end
  end

  describe "#upgrade_standby" do
    let(:candidate) { create_server(version: "16", upgrade_candidate: true) }

    before do
      strand.update(label: "upgrade_standby")
      nx.instance_variable_set(:@upgrade_candidate, candidate)
    end

    it "hops to update_metadata when upgrade succeeds" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("Succeeded")
      expect(candidate.vm.sshable).to receive(:d_clean).with("upgrade_postgres")
      expect { nx.upgrade_standby }.to hop("update_metadata")
    end

    it "hops to upgrade_failed when upgrade fails" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("Failed")
      expect { nx.upgrade_standby }.to hop("upgrade_failed")
    end

    it "starts upgrade when not started" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("NotStarted")
      expect(candidate).to receive(:configure_hash).and_return({"user_config" => {"wal_level" => "logical"}})
      expect(candidate.vm.sshable).to receive(:d_run).with("upgrade_postgres", "sudo", "postgres/bin/upgrade", "17", stdin: JSON.generate({"user_config" => {"wal_level" => "logical"}}))
      expect { nx.upgrade_standby }.to nap(5)
    end

    it "naps if status of the upgrade is unknown" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("Unknown")
      expect { nx.upgrade_standby }.to nap(5)
    end
  end

  describe "#update_metadata" do
    let(:candidate) { create_server(version: "16", upgrade_candidate: true) }

    before do
      strand.update(label: "update_metadata")
      nx.instance_variable_set(:@upgrade_candidate, candidate)
    end

    it "switches to new timeline with credentials and hops to wait_upgrade_candidate" do
      expect(candidate).to receive(:switch_to_new_timeline).with(parent_id: nil)
      expect { nx.update_metadata }.to hop("wait_upgrade_candidate")
      expect(candidate.reload).to have_attributes(
        version: "17",
        configure_set?: true,
        restart_set?: true,
      )
    end
  end

  describe "#wait_upgrade_candidate" do
    before do
      strand.update(label: "wait_upgrade_candidate")
    end

    it "hops to recycle_representative_server when candidate is ready" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      candidate.strand.update(label: "wait")
      expect { nx.wait_upgrade_candidate }.to hop("recycle_representative_server")
    end

    it "waits when candidate is waiting for restart" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      candidate.incr_restart
      expect { nx.wait_upgrade_candidate }.to nap(5)
    end

    it "waits when candidate is not ready" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      candidate.strand.update(label: "configure")
      expect { nx.wait_upgrade_candidate }.to nap(5)
    end
  end

  describe "#upgrade_failed" do
    let(:primary) { create_server(is_representative: true) }

    before do
      strand.update(label: "upgrade_failed")
      primary.strand.update(label: "wait_in_fence")
    end

    it "logs failure, raises a page and destroys candidate server" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      nx.instance_variable_set(:@upgrade_candidate, candidate)
      expect(candidate.vm.sshable).to receive(:_cmd).with("sudo journalctl -u upgrade_postgres").and_return("log line 1\nlog line 2")
      expect(Clog).to receive(:emit).with("Postgres resource upgrade failed", instance_of(Hash)).and_call_original.twice

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60).and change(Page, :count).by(1)
      expect(candidate.reload.destroy_set?).to be true
      expect(primary.reload.unfence_set?).to be true
    end

    it "unfences primary if it is fenced" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      nx.instance_variable_set(:@upgrade_candidate, candidate)
      allow(candidate.vm.sshable).to receive(:_cmd).and_return("")
      allow(Clog).to receive(:emit)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)

      expect(primary.reload.unfence_set?).to be true
    end

    it "does not unfence if primary is not fenced" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      nx.instance_variable_set(:@upgrade_candidate, candidate)
      primary.strand.update(label: "wait")
      allow(candidate.vm.sshable).to receive(:_cmd).and_return("")
      allow(Clog).to receive(:emit)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)

      expect(primary.reload.unfence_set?).to be false
    end

    it "handles case when candidate is nil" do
      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)

      expect(primary.reload.unfence_set?).to be true
    end

    it "handles case when candidate is not nil but destroy_set? is true" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      candidate.incr_destroy

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)

      expect(primary.reload.unfence_set?).to be true
    end
  end

  describe "#prune_servers" do
    before do
      strand.update(label: "prune_servers")
      pg.update(ha_type: "async")
    end

    it "destroys extra servers but keeps target_standby_count standbys" do
      representative = create_server(is_representative: true)
      keep_server = create_server
      extra_server = create_server
      unavailable_server = create_server
      unavailable_server.strand.update(label: "unavailable")
      recycling_server = create_server
      recycling_server.incr_recycle

      extra_server.update(created_at: Time.now - 120)
      keep_server.update(created_at: Time.now)

      expect { nx.prune_servers }.to hop("wait_prune_servers")

      expect(recycling_server.reload.destroy_set?).to be true
      expect(unavailable_server.reload.destroy_set?).to be true
      expect(extra_server.reload.destroy_set?).to be true
      expect(representative.reload.configure_set?).to be true
      expect(keep_server.reload.configure_set?).to be true
      expect(keep_server.destroy_set?).to be false

      servers_to_destroy_ids = strand.reload.stack.first["servers_to_destroy"]
      expect(servers_to_destroy_ids).to contain_exactly(recycling_server.id, unavailable_server.id, extra_server.id)
    end

    it "destroys servers with older versions" do
      old_server = create_server(version: "16")
      new_server = create_server(version: "17", is_representative: true)

      expect { nx.prune_servers }.to hop("wait_prune_servers")

      expect(old_server.reload.destroy_set?).to be true
      expect(new_server.reload.configure_set?).to be true

      servers_to_destroy_ids = strand.reload.stack.first["servers_to_destroy"]
      expect(servers_to_destroy_ids).to contain_exactly(old_server.id)
    end
  end

  describe "#wait_prune_servers" do
    before do
      strand.update(label: "wait_prune_servers")
    end

    it "naps if servers to destroy still exist" do
      server_to_destroy = create_server
      strand.stack.first["servers_to_destroy"] = [server_to_destroy.id]
      strand.modified!(:stack)
      strand.save_changes

      expect { nx.wait_prune_servers }.to nap(30)
    end

    it "pops if all servers to destroy have been removed" do
      strand.stack.first["servers_to_destroy"] = [SecureRandom.uuid]
      strand.modified!(:stack)
      strand.save_changes

      expect { nx.wait_prune_servers }.to exit({"msg" => "postgres resource is converged"})
    end
  end

  describe "#upgrade_candidate" do
    it "returns the upgrade candidate server" do
      candidate = create_server(version: "16", upgrade_candidate: true)
      expect(nx.upgrade_candidate).to eq(candidate)
    end
  end
end
