# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::HaPostgresResource do
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
    it "creates a strand and a test project" do
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(Project[name: "Postgres-HA-Test-Project"]).not_to be_nil
    end
  end

  describe "#start" do
    it "creates a minio cluster and hops to wait_minio_cluster" do
      expect { pgr_test.start }.to hop("wait_minio_cluster")
      minio_cluster_id = frame_value(pgr_test, "minio_cluster_id")
      expect(minio_cluster_id).not_to be_nil
      expect(MinioCluster[minio_cluster_id]).not_to be_nil
    end
  end

  describe "#wait_minio_cluster" do
    before do
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(postgres_service_project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(pgr_test, new_values: {"minio_cluster_id" => minio_cluster_strand.id})
      @minio_cluster_strand = minio_cluster_strand
    end

    it "naps for 10 seconds if the minio cluster is not ready" do
      expect { pgr_test.wait_minio_cluster }.to nap(10)
    end

    it "hops to create_postgres_resource if the minio cluster is ready" do
      @minio_cluster_strand.update(label: "wait")
      expect { pgr_test.wait_minio_cluster }.to hop("create_postgres_resource")
    end
  end

  describe "#create_postgres_resource" do
    it "creates a postgres resource" do
      expect { pgr_test.create_postgres_resource }.to hop("wait_postgres_resource")
      postgres_resource_id = frame_value(pgr_test, "postgres_resource_id")
      expect(postgres_resource_id).not_to be_nil
      expect(PostgresResource[postgres_resource_id]).not_to be_nil
    end
  end

  describe "#wait_postgres_resource" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      # Servers are not in "wait" state yet (still being provisioned)
      expect { pgr_test.wait_postgres_resource }.to nap(10)
    end

    it "hops to test_postgres if the postgres resource is ready" do
      pg = pgr_test.postgres_resource
      Prog::Postgres::PostgresServerNexus.assemble(resource_id: pg.id, timeline_id: pg.timeline.id, timeline_access: "fetch")
      pg.servers.each { |server| server.strand.update(label: "wait") }
      expect { pgr_test.wait_postgres_resource }.to hop("test_postgres")
    end
  end

  describe "#test_postgres" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      @pg_strand = pg_strand
    end

    it "fails if the postgres test fails" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres }.to hop("destroy_postgres")
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run test queries")
    end

    it "hops to trigger_failover if the postgres test passes" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres }.to hop("trigger_failover")
    end
  end

  describe "#trigger_failover" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "triggers a failover and hops to wait_failover" do
      primary = pgr_test.postgres_resource.servers.first
      sshable = Sshable.new
      allow(primary.vm).to receive(:sshable).and_return(sshable)
      allow(sshable).to receive(:_cmd).and_return("")
      expect { pgr_test.trigger_failover }.to hop("wait_failover")
    end
  end

  describe "#wait_failover" do
    it "naps for 3 minutes for the 1st time" do
      expect { pgr_test.wait_failover }.to nap(180)
      refresh_frame(pgr_test)
      expect(frame_value(pgr_test, "failover_wait_started")).to be true
    end

    it "hops to test_postgres_after_failover 2nd time" do
      refresh_frame(pgr_test, new_values: {"failover_wait_started" => true})
      expect { pgr_test.wait_failover }.to hop("test_postgres_after_failover")
    end
  end

  describe "#test_postgres_after_failover" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})

      # Set servers to "wait" state
      pg_strand.subject.reload
      pg_strand.subject.servers.each { |server| server.strand.update(label: "wait") }

      candidate_server = pgr_test.postgres_resource.servers.find { |s| s.ubid != pgr_test.frame["primary_ubid"] }
      sshable = Sshable.new
      allow(candidate_server.vm).to receive(:sshable).and_return(sshable)
      allow(sshable).to receive(:_cmd).and_return("")
    end

    it "fails if the postgres test fails" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries after failover")
    end

    it "logs that no primary was found after failover" do
      refresh_frame(pgr_test, new_values: {"primary_ubid" => pgr_test.postgres_resource.representative_server.ubid})
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("")
      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run read queries after failover")
      expect(Clog).to receive(:emit).with(/Postgres servers after failover: .*/).once.ordered
      expect(Clog).to receive(:emit).with("No new primary found after failover").once.ordered
      expect(Clog).to receive(:emit).with("Running read queries after failover").once.ordered

      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
    end

    it "hops to destroy_postgres if the standby does not exit read-only mode" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "")
      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to run write queries after failover")
    end

    it "hops to destroy_postgres if the postgres test succeeds" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("4159.90\n415.99\n4.1", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
      expect(frame_value(pgr_test, "fail_message")).to be_nil
    end
  end

  describe "#destroy_postgres" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(postgres_service_project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id, "minio_cluster_id" => minio_cluster_strand.id})
      @pg_strand = pg_strand
      @minio_cluster_strand = minio_cluster_strand
    end

    it "increments the destroy count and hops to destroy" do
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(@pg_strand.subject.destroy_set?).to be true
      expect(@minio_cluster_strand.subject.destroy_set?).to be true
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "hops to destroy if the postgres resource destroyed" do
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "minio_cluster_id" => nil})
      expect { pgr_test.wait_resources_destroyed }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "exits if no failure happened" do
      project = Project[pgr_test.frame["postgres_test_project_id"]]
      expect { pgr_test.destroy }.to exit({"msg" => "Postgres tests are finished!"})
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

  describe ".representative_server" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      @pg_strand = pg_strand
    end

    it "returns the representative server" do
      representative_server = pgr_test.representative_server
      expect(representative_server).to be_a(PostgresServer)
      expect(representative_server).to eq(@pg_strand.subject.representative_server)
    end
  end

  describe ".minio_cluster" do
    before do
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(postgres_service_project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(pgr_test, new_values: {"minio_cluster_id" => minio_cluster_strand.id})
      @minio_cluster_strand = minio_cluster_strand
    end

    it "returns the minio cluster" do
      minio_cluster = pgr_test.minio_cluster
      expect(minio_cluster).to be_a(MinioCluster)
      expect(minio_cluster.id).to eq(@minio_cluster_strand.id)
    end
  end
end
