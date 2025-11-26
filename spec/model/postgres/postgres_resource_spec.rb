# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  subject(:postgres_resource) {
    described_class.new(
      name: "pg-name",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id: Location::HETZNER_FSN1_ID
    ) { it.id = "6181ddb3-0002-8ad0-9aeb-084832c9273b" }
  }

  before do
    allow(postgres_resource).to receive(:project).and_return(instance_double(Project, get_ff_postgres_hostname_override: nil))
  end

  it "returns connection string without ubid qualifier" do
    expect(postgres_resource).to receive(:dns_zone).and_return("something").at_least(:once)
    expect(postgres_resource).to receive(:hostname_version).and_return("v1")
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.postgres.ubicloud.com:5432/postgres?channel_binding=require")
  end

  it "returns connection string with ubid qualifier" do
    expect(postgres_resource).to receive(:dns_zone).and_return("something").at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.pgc60xvcr00a5kbnggj1js4kkq.postgres.ubicloud.com:5432/postgres?channel_binding=require")
  end

  it "returns connection string with ip address if config is not set" do
    expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, vm: instance_double(Vm, ip4: "1.2.3.4", ip4_string: "1.2.3.4"))).at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@1.2.3.4:5432/postgres?channel_binding=require")
  end

  it "returns connection string as nil if there is no server" do
    expect(postgres_resource).to receive(:representative_server).and_return(nil).at_least(:once)
    expect(postgres_resource.connection_string).to be_nil
  end

  it "returns replication_connection_string" do
    s = postgres_resource.replication_connection_string(application_name: "pgubidstandby")
    expect(s).to include("ubi_replication@pgc60xvcr00a5kbnggj1js4kkq.postgres.ubicloud.com", "application_name=pgubidstandby", "sslcert=/etc/ssl/certs/server.crt")
  end

  it "returns has_enough_fresh_servers correctly" do
    expect(postgres_resource.servers).to receive(:count).and_return(1, 1)
    expect(postgres_resource).to receive(:target_server_count).and_return(1, 2)
    expect(postgres_resource.has_enough_fresh_servers?).to be(true)
    expect(postgres_resource.has_enough_fresh_servers?).to be(false)
  end

  it "returns has_enough_fresh_servers correctly during upgrades" do
    expect(postgres_resource).to receive(:version).at_least(:once).and_return("16")
    expect(postgres_resource).to receive(:target_version).at_least(:once).and_return("17")
    expect(postgres_resource).to receive(:upgrade_candidate_server).and_return(instance_double(PostgresServer), nil)
    expect(postgres_resource.has_enough_fresh_servers?).to be(true)
    expect(postgres_resource.has_enough_fresh_servers?).to be(false)
  end

  it "returns upgrade_candidate_server when candidate is available and location is not aws" do
    standby_server1 = instance_double(PostgresServer, representative_at: nil, created_at: Time.now - 3600)
    standby_server2 = instance_double(PostgresServer, representative_at: nil, created_at: Time.now)
    primary_server = instance_double(PostgresServer, representative_at: Time.now)
    boot_image = instance_double(BootImage, version: "20240801")
    volume = instance_double(VmStorageVolume, boot_image: boot_image, boot: true)
    vm = instance_double(Vm, vm_storage_volumes: [volume])
    location = instance_double(Location, aws?: false)

    expect(postgres_resource).to receive(:servers).and_return([primary_server, standby_server1, standby_server2])
    expect(standby_server1).to receive(:vm).and_return(vm)
    expect(standby_server2).to receive(:vm).and_return(vm)
    expect(postgres_resource).to receive(:location).and_return(location)

    # Should return the one with latest creation time
    expect(postgres_resource.upgrade_candidate_server).to eq(standby_server2)
  end

  it "returns upgrade_candidate_server when candidate is not available and location is not aws" do
    standby_server1 = instance_double(PostgresServer, representative_at: nil, created_at: Time.now - 3600)
    standby_server2 = instance_double(PostgresServer, representative_at: nil, created_at: Time.now)
    primary_server = instance_double(PostgresServer, representative_at: Time.now)
    boot_image = instance_double(BootImage, version: "20240729")
    volume = instance_double(VmStorageVolume, boot_image: boot_image, boot: true)
    vm = instance_double(Vm, vm_storage_volumes: [volume])
    location = instance_double(Location, aws?: false)

    expect(postgres_resource).to receive(:servers).and_return([primary_server, standby_server1, standby_server2])
    expect(standby_server1).to receive(:vm).and_return(vm)
    expect(standby_server2).to receive(:vm).and_return(vm)
    expect(postgres_resource).to receive(:location).and_return(location)

    expect(postgres_resource.upgrade_candidate_server).to be_nil
  end

  it "returns upgrade_candidate_server when candidate is available and location is aws" do
    standby_server1 = instance_double(PostgresServer, representative_at: nil, created_at: Time.now - 3600)
    standby_server2 = instance_double(PostgresServer, representative_at: nil, created_at: Time.now)
    primary_server = instance_double(PostgresServer, representative_at: Time.now)
    vm_1 = instance_double(Vm, boot_image: "ami-12345678")
    vm_2 = instance_double(Vm, boot_image: "ami-87654321")
    location = instance_double(Location, aws?: true)

    expect(PgAwsAmi).to receive(:where).with(aws_ami_id: "ami-12345678").and_return([instance_double(PgAwsAmi, aws_ami_id: "ami-12345678")])
    expect(PgAwsAmi).to receive(:where).with(aws_ami_id: "ami-87654321").and_return([])
    expect(postgres_resource).to receive(:servers).and_return([primary_server, standby_server1, standby_server2])
    expect(standby_server1).to receive(:vm).and_return(vm_1)
    expect(standby_server2).to receive(:vm).and_return(vm_2)
    expect(postgres_resource).to receive(:location).and_return(location)

    expect(postgres_resource.upgrade_candidate_server).to eq(standby_server1)
  end

  it "returns has_enough_ready_servers correctly when not upgrading" do
    expect(postgres_resource.servers).to receive(:count).and_return(1, 1)
    expect(postgres_resource).to receive(:target_server_count).and_return(1, 2)
    expect(postgres_resource.has_enough_ready_servers?).to be(true)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is not present" do
    expect(postgres_resource).to receive(:version).and_return("16")
    expect(postgres_resource).to receive(:target_version).and_return("17")
    expect(postgres_resource).to receive(:upgrade_candidate_server).at_least(:once).and_return(nil)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is not in wait state" do
    expect(postgres_resource).to receive(:version).and_return("16")
    expect(postgres_resource).to receive(:target_version).and_return("17")
    strand = instance_double(Strand, label: "wait_bootstrap_rhizome")
    candidate_server = instance_double(PostgresServer, strand: strand, synchronization_status: "ready")
    expect(postgres_resource).to receive(:upgrade_candidate_server).at_least(:once).and_return(candidate_server)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly when upgrading and the candidate is ready" do
    expect(postgres_resource).to receive(:version).and_return("16")
    expect(postgres_resource).to receive(:target_version).and_return("17")
    strand = instance_double(Strand, label: "wait")
    candidate_server = instance_double(PostgresServer, strand: strand, synchronization_status: "ready")
    expect(postgres_resource).to receive(:upgrade_candidate_server).at_least(:once).and_return(candidate_server)
    expect(postgres_resource.has_enough_ready_servers?).to be(true)
  end

  it "returns needs_convergence correctly when not upgrading" do
    expect(postgres_resource.servers).to receive(:any?).and_return(true, false, false)
    expect(postgres_resource.servers).to receive(:count).and_return(1, 2)
    expect(postgres_resource).to receive(:target_server_count).and_return(2, 2)
    expect(postgres_resource).to receive(:version).at_least(:once).and_return("17")
    expect(postgres_resource).to receive(:target_version).at_least(:once).and_return("17")

    expect(postgres_resource.needs_convergence?).to be(true)
    expect(postgres_resource.needs_convergence?).to be(true)
    expect(postgres_resource.needs_convergence?).to be(false)
  end

  it "returns needs_convergence correctly when upgrading" do
    expect(postgres_resource).to receive(:version).and_return("16")
    expect(postgres_resource).to receive(:target_version).and_return("17")
    expect(postgres_resource.servers).to receive(:any?).and_return(false)
    expect(postgres_resource.servers).to receive(:count).and_return(2)
    expect(postgres_resource).to receive(:target_server_count).and_return(2)
    expect(postgres_resource).to receive(:ongoing_failover?).and_return(false)

    expect(postgres_resource.needs_convergence?).to be(true)
  end

  it "#pg_firewall_rules returns empty array when there is no customer firewall" do
    expect(postgres_resource).to receive(:customer_firewall).and_return(nil)
    expect(postgres_resource.pg_firewall_rules).to eq []
  end

  describe "display_state" do
    it "returns 'deleting' when strand label is 'destroy'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "destroy")).at_least(:once)
      expect(postgres_resource.display_state).to eq("deleting")
    end

    it "returns 'unavailable' when representative server's strand label is 'unavailable'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "unavailable")))
      expect(postgres_resource.display_state).to eq("unavailable")
    end

    it "returns 'restoring_backup' when representative server's strand label is 'initialize_database_from_backup'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "initialize_database_from_backup"))).at_least(:once)
      expect(postgres_resource.display_state).to eq("restoring_backup")
    end

    it "returns 'replaying_wal' when representative server's strand label is 'wait_catch_up'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "wait_catch_up"))).at_least(:once)
      expect(postgres_resource.display_state).to eq("replaying_wal")
    end

    it "returns 'replaying_wal' when representative server's strand label is 'wait_synchronization'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "wait_synchronization"))).at_least(:once)
      expect(postgres_resource.display_state).to eq("replaying_wal")
    end

    it "returns 'finalizing_restore' when representative server's strand label is 'wait_recovery_completion'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "wait_recovery_completion"))).at_least(:once)
      expect(postgres_resource.display_state).to eq("finalizing_restore")
    end

    it "returns 'running' when strand label is 'wait' and has no children" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait", children: [])).at_least(:once)
      expect(postgres_resource.display_state).to eq("running")
    end

    it "returns 'creating' when strand is 'wait_server'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait_server", children: [])).at_least(:once)
      expect(postgres_resource.display_state).to eq("creating")
    end
  end

  it "returns in_maintenance_window? correctly" do
    expect(postgres_resource).to receive(:maintenance_window_start_at).and_return(nil)
    expect(postgres_resource.in_maintenance_window?).to be(true)

    expect(postgres_resource).to receive(:maintenance_window_start_at).and_return(1).at_least(:once)
    expect(Time).to receive(:now).and_return(Time.parse("2025-05-01 02:00:00Z"), Time.parse("2025-05-01 04:00:00Z"), Time.parse("2025-05-01 00:00:00Z"))
    expect(postgres_resource.in_maintenance_window?).to be(true)
    expect(postgres_resource.in_maintenance_window?).to be(false)
    expect(postgres_resource.in_maintenance_window?).to be(false)
  end

  it "returns target_standby_count correctly" do
    allow(postgres_resource).to receive(:ha_type).and_return(PostgresResource::HaType::NONE).at_least(:once)
    expect(postgres_resource.target_standby_count).to eq(0)
    allow(postgres_resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC).at_least(:once)
    expect(postgres_resource.target_standby_count).to eq(1)
    allow(postgres_resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC).at_least(:once)
    expect(postgres_resource.target_standby_count).to eq(2)
  end

  it "returns target_server_count correctly" do
    expect(postgres_resource).to receive(:target_standby_count).and_return(0, 1, 2)
    (0..2).each { expect(postgres_resource.target_server_count).to eq(it + 1) }
  end

  describe "#ongoing_failover?" do
    it "returns false if there is no ongoing failover" do
      expect(postgres_resource).to receive(:servers).and_return([instance_double(PostgresServer, taking_over?: false), instance_double(PostgresServer, taking_over?: false)])
      expect(postgres_resource.ongoing_failover?).to be false
    end

    it "returns true if there is an ongoing failover" do
      expect(postgres_resource).to receive(:servers).and_return([instance_double(PostgresServer, taking_over?: true), instance_double(PostgresServer, taking_over?: false)])
      expect(postgres_resource.ongoing_failover?).to be true
    end
  end

  describe "#hostname_suffix" do
    it "returns default hostname suffix if project is nil" do
      expect(postgres_resource).to receive(:project).and_return(nil)
      expect(postgres_resource.hostname_suffix).to eq(Config.postgres_service_hostname)
    end
  end

  describe "#upgrade_stage" do
    it "returns nil if there's no ongoing upgrade" do
      st = instance_double(Strand, children_dataset: instance_double(Sequel::Dataset))
      allow(postgres_resource).to receive(:strand).and_return(st)
      allow(st.children_dataset).to receive(:where).and_return([])
      expect(postgres_resource.upgrade_stage).to be_nil
    end

    it "returns the upgrade stage if there's an ongoing upgrade" do
      st = instance_double(Strand, children_dataset: instance_double(Sequel::Dataset))
      allow(postgres_resource).to receive(:strand).and_return(st)
      allow(st.children_dataset).to receive(:where).and_return([instance_double(Strand, prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby")])
      expect(postgres_resource.upgrade_stage).to eq("upgrade_standby")
    end
  end

  describe "#upgrade_status" do
    it "returns failed if the postgres resource upgrade failed" do
      expect(postgres_resource).to receive(:upgrade_stage).and_return("upgrade_failed")
      expect(postgres_resource.upgrade_status).to eq("failed")
    end

    it "returns not_running if the postgres resource does not need upgrade" do
      expect(postgres_resource).to receive(:upgrade_stage).and_return(nil)
      expect(postgres_resource.upgrade_status).to eq("not_running")
    end

    it "returns running if the postgres resource upgrade is in progress" do
      expect(postgres_resource).to receive(:upgrade_stage).and_return("upgrade_standby")
      expect(postgres_resource).to receive(:version).and_return("16")
      expect(postgres_resource.upgrade_status).to eq("running")
    end
  end

  describe "#can_upgrade?" do
    it "returns true if the postgres resource can be upgraded" do
      expect(postgres_resource).to receive(:target_version).and_return("17")
      expect(postgres_resource).to receive(:flavor).and_return(PostgresResource::Flavor::STANDARD)
      expect(postgres_resource.can_upgrade?).to be true
    end

    it "returns false if the postgres resource cannot be upgraded" do
      expect(postgres_resource).to receive(:flavor).and_return(PostgresResource::Flavor::LANTERN)
      expect(postgres_resource).to receive(:target_version).and_return("17")
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
end
