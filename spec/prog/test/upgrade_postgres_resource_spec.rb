# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::UpgradePostgresResource do
  subject(:pgr_test) { described_class.new(described_class.assemble) }

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
  end

  describe "#wait_postgres_resource" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      expect { pgr_test.wait_postgres_resource }.to nap(10)
    end

    it "hops to test_postgres_before_read_replica if the postgres resource is ready" do
      pg = pgr_test.postgres_resource
      Prog::Postgres::PostgresServerNexus.assemble(resource_id: pg.id, timeline_id: pg.timeline.id, timeline_access: "fetch")
      pg.servers.each { |server| server.strand.update(label: "wait") }
      expect { pgr_test.wait_postgres_resource }.to hop("test_postgres_before_read_replica")
    end
  end

  describe "#test_postgres_before_read_replica" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async", target_version: "17")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "fails if the postgres test fails" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_before_read_replica }.to hop("destroy_postgres")
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
      expect { pgr_test.test_postgres_with_read_replica }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries on primary before upgrade")
    end

    it "fails if read queries on replica fail before upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_with_read_replica }.to hop("destroy_postgres")
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
      expect { pgr_test.check_upgrade_progress }.to hop("destroy_postgres")
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
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Not all primary servers upgraded to version 18")
    end

    it "fails if not all replica servers are at version 18" do
      pgr_test.read_replica.servers.first.update(version: "17")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Not all replica servers upgraded to version 18")
    end

    it "fails if read queries on primary fail after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries on primary after upgrade")
    end

    it "fails if read queries on replica fail after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries on replica after upgrade")
    end

    it "fails if write queries on primary fail after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run write queries after upgrade")
    end

    it "fails if replica cannot read updated data after upgrade" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to read updated data on replica after upgrade")
    end

    it "hops to destroy_postgres if all tests pass" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")
      allow(pgr_test.read_replica.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_after_upgrade }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to be_nil
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
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil})
      expect(PrivateSubnet).to receive(:[]).with(project_id: pgr_test.frame["postgres_test_project_id"]).and_return(instance_double(PrivateSubnet))
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "verifies timelines are retained and explicitly destroys them" do
      timeline_id = SecureRandom.uuid
      timeline = instance_double(PostgresTimeline)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil, "timeline_ids" => [timeline_id]})
      expect(PrivateSubnet).to receive(:[]).with(project_id: pgr_test.frame["postgres_test_project_id"]).and_return(nil)
      expect(PostgresTimeline).to receive(:[]).with(timeline_id).and_return(timeline)
      expect(timeline).to receive(:incr_destroy)
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "hops to destroy if all resources and timelines are destroyed" do
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "read_replica_id" => nil, "timeline_ids" => []})
      expect { pgr_test.wait_resources_destroyed }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "exits if no failure happened" do
      project = Project[pgr_test.frame["postgres_test_project_id"]]
      expect { pgr_test.destroy }.to exit({"msg" => "Postgres upgrade tests are finished!"})
      expect(Project[project.id]).to be_nil
    end

    it "hops to failed if a failure happened" do
      refresh_frame(pgr_test, new_values: {"fail_message" => "Test failed"})
      project_id = pgr_test.frame["postgres_test_project_id"]
      expect { pgr_test.destroy }.to hop("failed")
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
