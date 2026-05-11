# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::UpgradePostgresResource do
  subject(:pgr_test) { described_class.new(pgr_strand) }

  let(:pgr_strand) { described_class.assemble }

  let(:postgres_service_project_id) { "546a1ed8-53e5-86d2-966c-fb782d2ae3ab" }
  let(:minio_service_project_id) { "f7207bf6-a031-4c98-aee6-4bb9cb03e821" }

  before do
    # Create service projects for tests
    Project.create_with_id(postgres_service_project_id, name: "service-project")
    Project.create_with_id(minio_service_project_id, name: "minio-service-project")
    allow(Config).to receive_messages(postgres_service_project_id:, minio_service_project_id:)
  end

  describe ".assemble" do
    it "creates a strand and a test project with default provider" do
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.stack.first["provider"]).to eq("metal")
      expect(Project[name: "Postgres-Upgrade-Test-Project"]).not_to be_nil
    end

    it "creates a strand with the given provider" do
      st = described_class.assemble(provider: "gcp")
      expect(st.stack.first["provider"]).to eq("gcp")
    end
  end

  describe "#before_run" do
    it "naps if pause is set" do
      Semaphore.incr(pgr_strand.id, "pause")
      expect { pgr_test.before_run }.to nap(60 * 60)
    end

    it "does nothing if pause is not set" do
      expect(pgr_test.before_run).to be_nil
    end
  end

  describe "#start" do
    it "creates a postgres resource with version 17 and async HA and hops to wait_postgres_resource" do
      expect { pgr_test.start }.to hop("wait_postgres_resource")
      postgres_resource_id = frame_value(pgr_test, "postgres_resource_id")
      expect(postgres_resource_id).not_to be_nil
      pg = PostgresResource[postgres_resource_id]
      expect(pg).not_to be_nil
      expect(pg.version).to eq("17")
      expect(pg.ha_type).to eq("async")
      expect(frame_value(pgr_test, "location_id")).to eq(Location::HETZNER_FSN1_ID)
    end

    it "creates a postgres resource on aws and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      allow(Aws::Credentials).to receive(:new).and_return(Aws::Credentials.new("access_key", "secret_key"))
      allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
      aws_strand = described_class.assemble(provider: "aws")
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      aws_pgr_test = described_class.new(aws_strand)
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredentialAws[location.id].access_key).to eq("access_key")
      pr = PostgresResource[aws_pgr_test.strand.stack.first["postgres_resource_id"]]
      expect(pr.target_vm_size).to eq(Option.aws_instance_type_name("m8gd", 2))
      expect(pr.target_storage_size_gib).to eq(Option::AWS_STORAGE_SIZE_OPTIONS["m8gd"][2].first.to_i)
    end

    it "skips creating aws credential if one already exists" do
      allow(Aws::Credentials).to receive(:new).and_return(Aws::Credentials.new("existing-key", "existing-secret"))
      allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
      aws_strand = described_class.assemble(provider: "aws")
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      LocationCredentialAws.create_with_id(location, access_key: "existing-key", secret_key: "existing-secret")
      aws_pgr_test = described_class.new(aws_strand)
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredentialAws[location.id].access_key).to eq("existing-key")
    end

    it "creates a postgres resource on gcp without family and hops to wait_postgres_resource" do
      sa_json = '{"project_id":"test-gcp-project","client_email":"test@test.iam.gserviceaccount.com"}'
      expect(Config).to receive(:e2e_gcp_credentials_base64_json).and_return(Base64.strict_encode64(sa_json))
      PgGceImage.dataset.destroy
      PgGceImage.create(
        gce_image_name: "postgres-ubuntu-2204-arm64-20260218",
        arch: "arm64",
        pg_versions: ["16", "17", "18"],
      )
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      pr = PostgresResource[gcp_pgr_test.strand.stack.first["postgres_resource_id"]]
      expect(pr.target_vm_size).to eq("c4a-standard-4")
      expect(pr.target_storage_size_gib).to eq(375)
    end

    it "creates a postgres resource on gcp with c4a-standard family and hops to wait_postgres_resource" do
      gcp_location = Location[provider: "gcp", project_id: nil]
      LocationCredentialGcp.create_with_id(gcp_location,
        project_id: "test-gcp-project",
        service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
        credentials_json: "{}")
      PgGceImage.dataset.destroy
      PgGceImage.create(
        gce_image_name: "postgres-ubuntu-2204-arm64-20260225",
        arch: "arm64",
        pg_versions: ["16", "17", "18"],
      )
      gcp_strand = described_class.assemble(provider: "gcp", family: "c4a-standard")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      pr = PostgresResource[gcp_pgr_test.strand.stack.first["postgres_resource_id"]]
      expect(pr.target_vm_size).to eq("c4a-standard-4")
      expect(pr.target_storage_size_gib).to eq(375)
    end

    it "creates resource on aws and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      aws_strand = described_class.assemble(provider: "aws")
      aws_pgr_test = described_class.new(aws_strand)
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredentialAws[location.id].access_key).to eq("access_key")
    end

    it "creates a PG16 resource without sync_replication_slots when start_version is 16" do
      pg16_test = described_class.new(described_class.assemble(start_version: "16"))
      expect { pg16_test.start }.to hop("wait_postgres_resource")
      pg = PostgresResource[frame_value(pg16_test, "postgres_resource_id")]
      expect(pg.version).to eq("16")
      expect(pg.user_config).not_to include("sync_replication_slots")
    end
  end

  describe "#wait_postgres_resource" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      expect { pgr_test.wait_postgres_resource }.to nap(10)
    end

    it "hops to setup_failover_slot if the postgres resource is ready" do
      pg = pgr_test.postgres_resource
      Prog::Postgres::PostgresServerNexus.assemble(resource_id: pg.id, timeline_id: pg.timeline.id, timeline_access: "fetch")
      pg.servers.each { |server| server.strand.update(label: "wait") }
      expect { pgr_test.wait_postgres_resource }.to hop("setup_failover_slot")
    end
  end

  describe "#setup_failover_slot" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      Prog::Postgres::PostgresServerNexus.assemble(resource_id: pg_strand.id, timeline_id: PostgresResource[pg_strand.id].timeline.id, timeline_access: "fetch")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "creates the slot and naps while the standby has not synced yet" do
      standby = pgr_test.postgres_resource.servers.find { !it.is_representative }
      expect(pgr_test.representative_server).to receive(:_run_query).with("SELECT 1 FROM pg_replication_slots WHERE slot_name = 'upgrade_test_slot'").and_return("")
      expect(pgr_test.representative_server).to receive(:_run_query).with(/pg_create_logical_replication_slot/).and_return("upgrade_test_slot")
      expect(standby).to receive(:_run_query).with(/synced AND NOT temporary/).and_return("")
      expect { pgr_test.setup_failover_slot }.to nap(10)
    end

    it "hops to test_postgres_before_read_replica once the slot is synced on the standby" do
      standby = pgr_test.postgres_resource.servers.find { !it.is_representative }
      expect(pgr_test.representative_server).to receive(:_run_query).with("SELECT 1 FROM pg_replication_slots WHERE slot_name = 'upgrade_test_slot'").and_return("1")
      expect(standby).to receive(:_run_query).with(/synced AND NOT temporary/).and_return("1")
      expect { pgr_test.setup_failover_slot }.to hop("test_postgres_before_read_replica")
    end

    it "fails if no standby exists" do
      pgr_test.postgres_resource.servers.reject(&:is_representative).each(&:destroy)
      pgr_test.postgres_resource.reload
      expect { pgr_test.setup_failover_slot }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("No standby found to verify failover slot sync")
    end

    it "creates a non-failover slot and skips sync wait for PG16" do
      refresh_frame(pgr_test, new_values: {"start_version" => "16"})
      expect(pgr_test.representative_server).to receive(:_run_query).with("SELECT 1 FROM pg_replication_slots WHERE slot_name = 'upgrade_test_slot'").and_return("")
      expect(pgr_test.representative_server).to receive(:_run_query).with(/pg_create_logical_replication_slot\('upgrade_test_slot', 'pgoutput', false, false\)\Z/).and_return("upgrade_test_slot")
      expect { pgr_test.setup_failover_slot }.to hop("test_postgres_before_read_replica")
    end
  end

  describe "#test_postgres_before_read_replica" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "fails if the postgres test fails" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_before_read_replica }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run test queries before read replica")
    end

    it "hops to create_read_replica if the postgres test passes" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_before_read_replica }.to hop("create_read_replica")
    end
  end

  describe "#create_read_replica" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "location_id" => Location::HETZNER_FSN1_ID})
    end

    it "creates a read replica and hops to wait_read_replica" do
      expect { pgr_test.create_read_replica }.to hop("wait_read_replica")
      read_replica_id = frame_value(pgr_test, "read_replica_id")
      expect(read_replica_id).not_to be_nil
      replica = PostgresResource[read_replica_id]
      expect(replica).not_to be_nil
      expect(replica.parent_id).to eq(pgr_test.postgres_resource.id)
    end
  end

  describe "#wait_read_replica" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "read_replica_id" => replica_strand.id})
      @replica_strand = replica_strand
    end

    it "naps for 10 seconds if the read replica is not ready" do
      expect { pgr_test.wait_read_replica }.to nap(10)
    end

    it "hops to test_postgres_with_read_replica if the read replica is ready" do
      replica = pgr_test.read_replica
      replica.servers.each { |server| server.strand.update(label: "wait") }
      expect { pgr_test.wait_read_replica }.to hop("test_postgres_with_read_replica")
    end
  end

  describe "#test_postgres_with_read_replica" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "read_replica_id" => replica_strand.id})
    end

    it "fails if read queries on primary fail before upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_with_read_replica }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries on primary before upgrade")
    end

    it "fails if read queries on replica fail before upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_with_read_replica }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries on replica before upgrade")
    end

    it "hops to trigger_upgrade if both primary and replica pass tests" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_with_read_replica }.to hop("trigger_upgrade")
    end
  end

  describe "#trigger_upgrade" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "read_replica_id" => replica_strand.id})
    end

    it "updates target_version to 18 and hops to check_upgrade_progress" do
      expect { pgr_test.trigger_upgrade }.to hop("check_upgrade_progress")
      pgr_test.postgres_resource.reload
      pgr_test.read_replica.reload
      expect(pgr_test.postgres_resource.target_version).to eq("18")
      expect(pgr_test.read_replica.target_version).to eq("18")
    end
  end

  describe "#check_upgrade_progress" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "read_replica_id" => replica_strand.id})
      DB.transaction do
        pg_strand.subject.update(target_version: "18")
        replica_strand.subject.update(target_version: "18")
      end
    end

    it "naps if upgrade is not complete" do
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end

    it "fails if any servers are in failed state" do
      pgr_test.postgres_resource.servers.first.strand.update(label: "failed")
      expect { pgr_test.check_upgrade_progress }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Upgrade failed: some servers are in failed state")
    end

    it "hops to test_postgres_after_upgrade when all servers upgraded to version 18" do
      pgr_test.postgres_resource.servers.each do |server|
        server.update(version: "18")
        server.strand.update(label: "wait")
      end
      pgr_test.read_replica.servers.each do |server|
        server.update(version: "18")
        server.strand.update(label: "wait")
      end
      expect { pgr_test.check_upgrade_progress }.to hop("test_postgres_after_upgrade")
    end

    it "logs blob storage URL when blob storage is configured" do
      resource = pgr_test.postgres_resource
      server = resource.servers.first
      allow(server.timeline).to receive_messages(blob_storage: double(url: "http://minio.example.com"), backups: [])
      allow(resource).to receive(:servers).and_return([server])
      allow(pgr_test).to receive(:postgres_resource).and_return(resource)
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end

    it "logs journalctl output for a server stuck in initialize_database_from_backup" do
      resource = pgr_test.postgres_resource
      server = resource.servers.first
      server.strand.update(label: "initialize_database_from_backup")
      sshable = Sshable.new
      allow(server).to receive(:vm).and_return(instance_double(Vm, sshable:))
      allow(resource).to receive(:servers).and_return([server])
      allow(pgr_test).to receive(:postgres_resource).and_return(resource)
      allow(sshable).to receive(:_cmd).with("journalctl -u postgres-server -n 100 --no-pager").and_return("Journal output")
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end

    it "handles errors when fetching initialize_database_from_backup logs" do
      resource = pgr_test.postgres_resource
      server = resource.servers.first
      server.strand.update(label: "initialize_database_from_backup")
      sshable = Sshable.new
      allow(sshable).to receive(:_cmd).and_raise(RuntimeError, "SSH connection failed")
      allow(server).to receive(:vm).and_return(instance_double(Vm, sshable:))
      allow(resource).to receive(:servers).and_return([server])
      allow(pgr_test).to receive(:postgres_resource).and_return(resource)
      allow(sshable).to receive(:_cmd).with("journalctl -u postgres-server -n 100 --no-pager").and_return("Journal output")
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end

    it "logs LSN info for a non-read-replica server in wait_catch_up" do
      resource = pgr_test.postgres_resource
      server = resource.servers.first
      server.strand.update(label: "wait_catch_up")
      rep_server = resource.representative_server
      allow(server).to receive_messages(resource:, current_lsn: "0/1000000")
      allow(rep_server).to receive(:current_lsn).and_return("0/2000000")
      allow(resource).to receive(:servers).and_return([server])
      allow(pgr_test).to receive(:postgres_resource).and_return(resource)
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end

    it "logs LSN info for a read-replica server in wait_catch_up" do
      resource = pgr_test.postgres_resource
      rep_server = resource.representative_server
      replica = pgr_test.read_replica
      server = replica.servers.first
      server.strand.update(label: "wait_catch_up")
      allow(server).to receive_messages(resource: double(read_replica?: true, parent: resource), current_lsn: "0/1000000")
      allow(rep_server).to receive(:current_lsn).and_return("0/2000000")
      allow(replica).to receive(:servers).and_return([server])
      allow(pgr_test).to receive(:postgres_resource).and_return(resource)
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end

    it "logs no parent server found when read-replica resource has no parent" do
      replica = pgr_test.read_replica
      server = replica.servers.first
      server.strand.update(label: "wait_catch_up")
      allow(server).to receive(:resource).and_return(double(read_replica?: true, parent: nil))
      allow(replica).to receive(:servers).and_return([server])
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end

    it "handles an exception when fetching LSN info for a server in wait_catch_up" do
      resource = pgr_test.postgres_resource
      server = resource.servers.first
      server.strand.update(label: "wait_catch_up")
      allow(server).to receive(:current_lsn).and_raise(RuntimeError, "connection refused")
      allow(resource).to receive(:servers).and_return([server])
      allow(pgr_test).to receive(:postgres_resource).and_return(resource)
      expect { pgr_test.check_upgrade_progress }.to nap(60)
    end
  end

  describe "#test_postgres_after_upgrade" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "read_replica_id" => replica_strand.id})

      # Simulate upgrade completion
      pgr_test.postgres_resource.servers.each { |s| s.update(version: "18") }
      pgr_test.read_replica.servers.each { |s| s.update(version: "18") }
    end

    it "fails if not all primary servers are at version 18" do
      pgr_test.postgres_resource.servers.first.update(version: "17")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Not all primary servers upgraded to version 18")
    end

    it "fails if not all replica servers are at version 18" do
      pgr_test.read_replica.servers.first.update(version: "17")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Not all replica servers upgraded to version 18")
    end

    it "fails if read queries on primary fail after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries on primary after upgrade")
    end

    it "fails if read queries on replica fail after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries on replica after upgrade")
    end

    it "fails if write queries on primary fail after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run write queries after upgrade")
    end

    it "fails if replica cannot read updated data after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to read updated data on replica after upgrade")
    end

    it "hops to destroy if all tests pass" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1", "t")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to be_nil
    end

    it "fails if the failover slot is missing after PG17+ upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1", "")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to start_with("Unexpected slot state")
    end

    it "passes when PG16 upgrade drops the logical slot" do
      refresh_frame(pgr_test, new_values: {"start_version" => "16"})
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1", "")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "4159.90\n415.99\n4.1")
      pgr_test.postgres_resource.servers.each { |s| s.update(version: "17") }
      pgr_test.read_replica.servers.each { |s| s.update(version: "17") }
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to be_nil
    end

    it "fails when PG16 upgrade leaves a slot that should have been dropped" do
      refresh_frame(pgr_test, new_values: {"start_version" => "16"})
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1", "f")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "4159.90\n415.99\n4.1")
      pgr_test.postgres_resource.servers.each { |s| s.update(version: "17") }
      pgr_test.read_replica.servers.each { |s| s.update(version: "17") }
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to start_with("Unexpected slot state")
    end
  end

  describe "#destroy_postgres" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "read_replica_id" => replica_strand.id})
      @pg_strand = pg_strand
      @replica_strand = replica_strand
    end

    it "increments the destroy count, tracks timeline_ids, and hops to wait_resources_destroyed" do
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(@pg_strand.subject.destroy_set?).to be true
      expect(@replica_strand.subject.destroy_set?).to be true
      expect(frame_value(pgr_test, "timeline_ids")).not_to be_empty
    end

    it "handles nil read_replica gracefully" do
      refresh_frame(pgr_test, new_values: {"read_replica_id" => nil})
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(@pg_strand.subject.destroy_set?).to be true
      expect(frame_value(pgr_test, "timeline_ids")).not_to be_empty
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if the read replica isn't deleted yet" do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => replica_strand.id})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if private subnet still exists" do
      project_id = pgr_test.frame["postgres_test_project_id"]
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil})
      PrivateSubnet.create(
        name: "upgrade-test-subnet", project_id:, location_id: Location::HETZNER_FSN1_ID,
        net4: "10.0.0.0/26", net6: "fd00::/64",
      )
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if GCP VPC still exists" do
      project_id = pgr_test.frame["postgres_test_project_id"]
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil})
      GcpVpc.create(project_id:, location_id: Location::HETZNER_FSN1_ID, name: "upgrade-test-vpc")
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "verifies timelines are retained and explicitly destroys them" do
      tl = PostgresTimeline.create(location_id: Location::HETZNER_FSN1_ID)
      Strand.create_with_id(tl, prog: "Postgres::PostgresTimelineNexus", label: "wait")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil, "timeline_ids" => [tl.id]})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
      expect(Semaphore.where(strand_id: tl.id, name: "destroy").count).to eq(1)
    end

    it "hops to destroy if all resources and timelines are destroyed" do
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil, "timeline_ids" => []})
      expect { pgr_test.wait_resources_destroyed }.to hop("finish")
    end

    it "hops to finish when timeline_ids was never set in the frame" do
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil})
      expect(pgr_test).not_to receive(:verify_timelines_destroyed)
      expect { pgr_test.wait_resources_destroyed }.to hop("finish")
    end
  end

  describe "#finish" do
    it "exits if no failure happened" do
      project = Project[pgr_test.frame["postgres_test_project_id"]]
      expect { pgr_test.finish }.to exit({"msg" => "Postgres tests are finished!"})
      expect(Project[project.id]).to be_nil
    end

    it "hops to failed if a failure happened" do
      refresh_frame(pgr_test, new_values: {"fail_message" => "Test failed"})
      project_id = pgr_test.frame["postgres_test_project_id"]
      expect { pgr_test.finish }.to hop("failed")
      expect(Project[project_id]).to be_nil
    end
  end

  describe "#failed" do
    it "naps" do
      expect { pgr_test.failed }.to nap(15)
    end
  end

  describe "#postgres_test_project" do
    it "returns the postgres test project" do
      project = pgr_test.postgres_test_project
      expect(project).to be_a(Project)
      expect(project.name).to eq("Postgres-Upgrade-Test-Project")
    end
  end

  describe "#postgres_resource" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      @pg_strand = pg_strand
    end

    it "returns the postgres resource" do
      postgres_resource = pgr_test.postgres_resource
      expect(postgres_resource).to be_a(PostgresResource)
      expect(postgres_resource.id).to eq(@pg_strand.id)
    end
  end

  describe "#read_replica" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      replica_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg-replica", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: pg_strand.id)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "read_replica_id" => replica_strand.id})
      @replica_strand = replica_strand
    end

    it "returns the read replica" do
      read_replica = pgr_test.read_replica
      expect(read_replica).to be_a(PostgresResource)
      expect(read_replica.id).to eq(@replica_strand.id)
    end
  end

  describe "#representative_server" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      @pg_strand = pg_strand
    end

    it "returns the representative server" do
      representative_server = pgr_test.representative_server
      expect(representative_server).to be_a(PostgresServer)
      expect(representative_server).to eq(@pg_strand.subject.representative_server)
    end
  end

  describe "#test_queries_sql" do
    it "reads the test queries from file" do
      expect(pgr_test.test_queries_sql).to include("DROP TABLE IF EXISTS public.order_analytics")
    end
  end

  describe "#read_queries_sql" do
    it "reads the read queries from file" do
      expect(pgr_test.read_queries_sql).to include("SELECT ROUND(SUM(order_amount)")
    end
  end
end
