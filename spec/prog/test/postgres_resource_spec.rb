# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::PostgresResource do
  subject(:pgr_test) { described_class.new(described_class.assemble) }

  let(:test_project) { Project.create(name: "test-project") }
  let(:service_project) { Project.create(name: "service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: test_project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  let(:timeline) { PostgresTimeline.create(location_id:) }

  let(:postgres_resource) {
    pr = PostgresResource.create(
      name: "pg-test",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id:,
      project_id: test_project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    )
    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait")
    pr
  }

  def create_postgres_server
    vm = Prog::Vm::Nexus.assemble_with_sshable(
      test_project.id, name: "pg-vm-#{SecureRandom.hex(4)}", private_subnet_id: private_subnet.id,
      location_id:, unix_user: "ubi"
    ).subject
    server = PostgresServer.create(
      timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17"
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
    server
  end

  def setup_postgres_resource(with_server: true)
    postgres_resource
    create_postgres_server if with_server
    refresh_frame(pgr_test, new_values: {"postgres_resource_id" => postgres_resource.id})
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe ".assemble" do
    it "creates a strand and service projects" do
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
    end
  end

  describe "#start" do
    it "creates resource on metal and hops to wait_postgres_resource" do
      expect { pgr_test.start }.to hop("wait_postgres_resource")
    end

    it "creates resource on aws and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      aws_strand = described_class.assemble(provider: "aws")
      aws_pgr_test = described_class.new(aws_strand)
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[location.id].access_key).to eq("access_key")
    end

    it "skips aws credential creation when credential already exists" do
      aws_strand = described_class.assemble(provider: "aws")
      aws_pgr_test = described_class.new(aws_strand)
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      LocationCredential.create_with_id(location.id, access_key: "existing_key", secret_key: "existing_secret")
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[location.id].access_key).to eq("existing_key")
    end

    it "creates resource on gcp and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_gcp_credentials_json).and_return("{}")
      expect(Config).to receive(:e2e_gcp_project_id).and_return("test-project")
      expect(Config).to receive(:e2e_gcp_service_account_email).and_return("test@test.iam.gserviceaccount.com")
      gcp_location = Location[provider: "gcp", project_id: nil]
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "test-project",
        gce_image_name: "postgres-ubuntu-2204-x64-20260218",
        pg_version: "17", arch: "x64")
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[gcp_location.id].credentials_json).to eq("{}")
    end

    it "skips gcp credential creation when credential already exists" do
      location = Location[provider: "gcp", project_id: nil]
      LocationCredential.create_with_id(location.id, credentials_json: "{}", project_id: "existing-project", service_account_email: "existing@test.iam.gserviceaccount.com")
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "existing-project",
        gce_image_name: "postgres-ubuntu-2204-x64-20260218",
        pg_version: "17", arch: "x64")
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[location.id].project_id).to eq("existing-project")
    end

    it "creates resource on gcp with c4a-standard family and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_gcp_credentials_json).and_return("{}")
      expect(Config).to receive(:e2e_gcp_project_id).and_return("test-project")
      expect(Config).to receive(:e2e_gcp_service_account_email).and_return("test@test.iam.gserviceaccount.com")
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "test-project",
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
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }

    it "hops to test_postgres if the postgres resource is ready" do
      expect(sshable).to receive(:_cmd).and_return("1\n")
      expect { pgr_test.wait_postgres_resource }.to hop("test_postgres")
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { pgr_test.wait_postgres_resource }.to nap(10)
    end
  end

  describe "#test_postgres" do
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }

    it "fails if the basic connectivity test fails" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { pgr_test.test_postgres }.to hop("verify_ipv6_connectivity")
    end

    it "hops to verify_ipv6_connectivity if the basic connectivity test passes" do
      expect(sshable).to receive(:_cmd).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1\n")
      expect { pgr_test.test_postgres }.to hop("verify_ipv6_connectivity")
    end
  end

  describe "#verify_ipv6_connectivity" do
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }
    let(:vm) { pgr_test.representative_server.vm }

    it "skips if vm has no ipv6 and hops to destroy_postgres" do
      allow(vm).to receive(:ip6).and_return(nil)
      expect { pgr_test.verify_ipv6_connectivity }.to hop("destroy_postgres")
    end

    it "verifies ipv6 connectivity and hops to destroy_postgres" do
      allow(vm).to receive_messages(ip6: "2001:db8::1", ip6_string: "2001:db8::1")
      expect(sshable).to receive(:_cmd).and_return("1\n")
      expect { pgr_test.verify_ipv6_connectivity }.to hop("destroy_postgres")
    end

    it "sets fail_message if psql over ipv6 fails" do
      allow(vm).to receive_messages(ip6: "2001:db8::1", ip6_string: "2001:db8::1")
      expect(sshable).to receive(:_cmd).and_return("error\n")
      expect { pgr_test.verify_ipv6_connectivity }.to hop("destroy_postgres")
      expect(frame_value(pgr_test, "fail_message")).to eq("Failed to connect to PostgreSQL over IPv6")
    end
  end

  describe "#destroy_postgres" do
    before { setup_postgres_resource(with_server: false) }

    it "increments the destroy count and hops to wait_resources_destroyed" do
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      setup_postgres_resource(with_server: false)
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if the private subnet isn't deleted yet" do
      project_id = pgr_test.strand.stack.first["postgres_test_project_id"]
      PrivateSubnet.create(name: "subnet", project_id:, location_id:, net4: "10.0.0.0/26", net6: "fd00::/64")
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "verifies timelines are retained and explicitly destroys them" do
      tl = PostgresTimeline.create(location_id:)
      Strand.create_with_id(tl, prog: "Postgres::PostgresTimelineNexus", label: "wait")
      refresh_frame(pgr_test, new_values: {"timeline_ids" => [tl.id]})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
      expect(Semaphore.where(strand_id: tl.id, name: "destroy").count).to eq(1)
    end

    it "hops to destroy if the postgres resource destroyed" do
      expect { pgr_test.wait_resources_destroyed }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "exits successfully if no failure happened" do
      expect { pgr_test.destroy }.to exit({"msg" => "Postgres tests are finished!"})
    end

    it "hops to failed if a failure happened" do
      pgr_test.strand.stack.first["fail_message"] = "Test failed"
      pgr_test.strand.modified!(:stack)
      pgr_test.strand.save_changes
      fresh_pgr_test = described_class.new(pgr_test.strand)
      expect { fresh_pgr_test.destroy }.to hop("failed")
    end
  end

  describe "#failed" do
    it "naps" do
      expect { pgr_test.failed }.to nap(15)
    end
  end

  describe "#representative_server" do
    before { setup_postgres_resource }

    it "returns the representative server" do
      expect(pgr_test.representative_server).to eq(postgres_resource.representative_server)
    end
  end
end
