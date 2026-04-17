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
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }

  let(:timeline) { create_postgres_timeline(location_id:) }

  let(:postgres_resource) { create_postgres_resource(project: test_project, location_id:) }

  def setup_postgres_resource(with_server: true)
    postgres_resource
    postgres_resource.strand.update(label: "wait")
    create_postgres_server(resource: postgres_resource, timeline:).strand.update(label: "wait") if with_server
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
      LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredentialAws[location.id].access_key).to eq("access_key")
    end

    it "skips aws credential creation when credential already exists" do
      aws_strand = described_class.assemble(provider: "aws")
      aws_pgr_test = described_class.new(aws_strand)
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      LocationCredentialAws.create_with_id(location, access_key: "existing_key", secret_key: "existing_secret")
      expect { aws_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredentialAws[location.id].access_key).to eq("existing_key")
    end

    it "creates resource on gcp and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_gcp_credentials_json).and_return("{}")
      expect(Config).to receive(:e2e_gcp_project_id).and_return("test-project")
      expect(Config).to receive(:e2e_gcp_service_account_email).and_return("test@test.iam.gserviceaccount.com")
      gcp_location = Location[provider: "gcp", project_id: nil]
      PgGceImage.dataset.destroy
      PgGceImage.create(
        gce_image_name: "postgres-ubuntu-2204-arm64-20260218",
        arch: "arm64",
        pg_versions: ["16", "17", "18"],
      )
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredentialGcp[gcp_location.id].credentials_json).to eq("{}")
    end

    it "skips gcp credential creation when credential already exists" do
      location = Location[provider: "gcp", project_id: nil]
      LocationCredentialGcp.create_with_id(location, credentials_json: "{}", project_id: "existing-project", service_account_email: "existing@test.iam.gserviceaccount.com")
      PgGceImage.dataset.destroy
      PgGceImage.create(
        gce_image_name: "postgres-ubuntu-2204-arm64-20260218",
        arch: "arm64",
        pg_versions: ["16", "17", "18"],
      )
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_pgr_test = described_class.new(gcp_strand)
      expect { gcp_pgr_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredentialGcp[location.id].project_id).to eq("existing-project")
    end

    it "creates resource on gcp with c4a-standard family and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_gcp_credentials_json).and_return("{}")
      expect(Config).to receive(:e2e_gcp_project_id).and_return("test-project")
      expect(Config).to receive(:e2e_gcp_service_account_email).and_return("test@test.iam.gserviceaccount.com")
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
      expect { pgr_test.test_postgres }.to hop("destroy_postgres")
    end

    it "hops to destroy_postgres if the basic connectivity test passes" do
      expect(sshable).to receive(:_cmd).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1\n")
      expect { pgr_test.test_postgres }.to hop("destroy_postgres")
    end
  end

  describe "#destroy_postgres" do
    before { setup_postgres_resource(with_server: true) }

    it "increments the destroy count and hops to wait_resources_destroyed" do
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
      expect(frame_value(pgr_test, "timeline_ids")).not_to be_empty
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
      expect { pgr_test.wait_resources_destroyed }.to hop("finish")
    end
  end

  describe "#finish" do
    it "exits successfully if no failure happened" do
      expect { pgr_test.finish }.to exit({"msg" => "Postgres tests are finished!"})
    end

    it "hops to failed if a failure happened" do
      pgr_test.strand.stack.first["fail_message"] = "Test failed"
      pgr_test.strand.modified!(:stack)
      pgr_test.strand.save_changes
      fresh_pgr_test = described_class.new(pgr_test.strand)
      expect { fresh_pgr_test.finish }.to hop("failed")
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
