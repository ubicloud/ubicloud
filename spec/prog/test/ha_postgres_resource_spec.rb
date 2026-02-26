# frozen_string_literal: true

require "aws-sdk-ec2"
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
      expect(st.stack.first["provider"]).to eq("metal")
    end

    it "accepts a provider parameter" do
      st = described_class.assemble(provider: "gcp")
      expect(st.stack.first["provider"]).to eq("gcp")
    end
  end

  describe "#start" do
    it "creates a postgres resource on metal and hops to wait_postgres_resource" do
      expect { pgr_test.start }.to hop("wait_postgres_resource")
      postgres_resource_id = frame_value(pgr_test, "postgres_resource_id")
      expect(postgres_resource_id).not_to be_nil
      expect(PostgresResource[postgres_resource_id]).not_to be_nil
    end

    it "creates a postgres resource on aws and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      allow(Aws::Credentials).to receive(:new).and_return(Aws::Credentials.new("access_key", "secret_key"))
      allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
      aws_strand = described_class.assemble(provider: "aws")
      location = Location[provider: "aws", project_id: nil, name: "us-east-1"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "use1-az1")
      aws_pgr_test = described_class.new(aws_strand)
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[location.id].access_key).to eq("access_key")
    end

    it "skips creating aws credential if one already exists" do
      allow(Aws::Credentials).to receive(:new).and_return(Aws::Credentials.new("existing-key", "existing-secret"))
      allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
      aws_strand = described_class.assemble(provider: "aws")
      location = Location[provider: "aws", project_id: nil, name: "us-east-1"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "use1-az1")
      LocationCredential.create_with_id(location.id, access_key: "existing-key", secret_key: "existing-secret")
      aws_pgr_test = described_class.new(aws_strand)
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[location.id].access_key).to eq("existing-key")
    end

    it "creates a postgres resource on gcp and hops to wait_postgres_resource" do
      gcp_location = Location[provider: "gcp", project_id: nil]
      unless LocationCredential[gcp_location.id]
        LocationCredential.create_with_id(gcp_location.id,
          project_id: "test-gcp-project",
          service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
          credentials_json: "{}")
      end
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "test-gcp-project",
        gce_image_name: "postgres-ubuntu-2204-x64-20260218",
        pg_version: "17", arch: "x64")
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
    end

    it "creates LocationCredential on gcp when one does not pre-exist" do
      expect(Config).to receive(:e2e_gcp_credentials_json).and_return("{}")
      expect(Config).to receive(:e2e_gcp_project_id).and_return("test-gcp-project")
      expect(Config).to receive(:e2e_gcp_service_account_email).and_return("test@test.iam.gserviceaccount.com")
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "test-gcp-project",
        gce_image_name: "postgres-ubuntu-2204-x64-20260218",
        pg_version: "17", arch: "x64")
      gcp_location = Location[provider: "gcp", project_id: nil]
      # Ensure no credential exists
      LocationCredential[gcp_location.id]&.destroy
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[gcp_location.id]).not_to be_nil
    end

    it "creates a postgres resource on gcp with c4a-standard family and hops to wait_postgres_resource" do
      gcp_location = Location[provider: "gcp", project_id: nil]
      unless LocationCredential[gcp_location.id]
        LocationCredential.create_with_id(gcp_location.id,
          project_id: "test-gcp-project",
          service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
          credentials_json: "{}")
      end
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "test-gcp-project",
        gce_image_name: "postgres-ubuntu-2204-arm64-20260225",
        pg_version: "17", arch: "arm64")
      gcp_strand = described_class.assemble(provider: "gcp", family: "c4a-standard")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      pr = PostgresResource[gcp_pgr_test.strand.stack.first["postgres_resource_id"]]
      expect(pr.target_vm_size).to eq("c4a-standard-4")
      expect(pr.target_storage_size_gib).to eq(375)
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

    it "hops to verify_wal_archiving if the postgres test passes" do
      allow(pgr_test.representative_server).to receive(:_run_query).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")
      expect { pgr_test.test_postgres }.to hop("verify_wal_archiving")
    end
  end

  describe "#verify_wal_archiving" do
    before do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
    end

    it "hops to trigger_failover if wal files are found" do
      primary = pgr_test.postgres_resource.servers.find { it.timeline_access == "push" }
      allow(primary.timeline).to receive(:list_objects).with("wal_005/").and_return([instance_double(Aws::S3::Types::Object)])
      expect { pgr_test.verify_wal_archiving }.to hop("trigger_failover")
    end

    it "naps if no wal files are found yet" do
      primary = pgr_test.postgres_resource.servers.find { it.timeline_access == "push" }
      allow(primary.timeline).to receive(:list_objects).with("wal_005/").and_return([])
      expect { pgr_test.verify_wal_archiving }.to nap(15)
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
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      @pg_strand = pg_strand
    end

    it "increments the destroy count and hops to wait_resources_destroyed" do
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(@pg_strand.subject.destroy_set?).to be true
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      pg_strand = Prog::Postgres::PostgresResourceNexus.assemble(project_id: pgr_test.frame["postgres_test_project_id"], location_id: Location::HETZNER_FSN1_ID, name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 128, ha_type: "async")
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => pg_strand.id})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if private subnet still exists" do
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil})
      expect(PrivateSubnet).to receive(:[]).with(project_id: pgr_test.frame["postgres_test_project_id"]).and_return(instance_double(PrivateSubnet))
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "verifies timelines are retained and explicitly destroys them" do
      timeline_id = SecureRandom.uuid
      timeline = instance_double(PostgresTimeline)
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil, "timeline_ids" => [timeline_id]})
      expect(PrivateSubnet).to receive(:[]).with(project_id: pgr_test.frame["postgres_test_project_id"]).and_return(nil)
      expect(PostgresTimeline).to receive(:[]).with(timeline_id).and_return(timeline)
      expect(timeline).to receive(:incr_destroy)
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "hops to destroy if the postgres resource destroyed" do
      refresh_frame(pgr_test, new_values: {"postgres_resource_id" => nil})
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
end
