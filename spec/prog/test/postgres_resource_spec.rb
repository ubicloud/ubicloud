# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::PostgresResource do
  subject(:pgr_test) { described_class.new(pgr_strand) }

  let(:pgr_strand) { described_class.assemble }

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
      st = nil
      expect { st = described_class.assemble }.to change { Project.select_order_map(:name) }.from(["service-project"]).to(["Postgres-Test-Project", "service-project"])
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
    end

    it "uses existing project if Config.local_e2e_postgres_test_project_id" do
      st = nil
      project = Project.create(name: "foo")
      expect(Config).to receive(:local_e2e_postgres_test_project_id).and_return(project.id).at_least(:once)
      expect { st = described_class.assemble }.not_to change { Project.select_order_map(:name) }
      expect(st).to be_a Strand
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
      expect { pgr_test.test_postgres }.to hop("destroy")
    end

    it "hops to destroy if the basic connectivity test passes" do
      expect(sshable).to receive(:_cmd).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1\n")
      expect { pgr_test.test_postgres }.to hop("destroy")
    end
  end

  describe "#destroy" do
    before { setup_postgres_resource(with_server: true) }

    it "hops to destroy postgres and does not page if no failure" do
      expect { pgr_test.destroy }.to hop("destroy_postgres")
      expect(Page.count).to eq 0
    end

    it "hops to destroy postgres and does not page if failure but not local e2e" do
      refresh_frame(pgr_test, new_values: {"fail_message" => "Test failed"})
      expect { pgr_test.destroy }.to hop("destroy_postgres")
      expect(Page.count).to eq 0
    end

    it "hops to destroy postgres and does not page if local e2e but no failure" do
      refresh_frame(pgr_test, new_values: {"local_e2e" => true})
      expect { pgr_test.destroy }.to hop("destroy_postgres")
      expect(Page.count).to eq 0
    end

    it "naps and pages if failure and local e2e" do
      refresh_frame(pgr_test, new_values: {"fail_message" => "Test failed", "local_e2e" => true})
      expect { pgr_test.destroy }.to nap(60 * 60 * 24 * 365)
      pages = Page.all
      expect(pages.size).to eq 1
      expect(pages[0].severity).to eq "info"
    end
  end

  describe "#destroy_postgres" do
    before { setup_postgres_resource(with_server: true) }

    it "increments the destroy count and hops to wait_resources_destroyed" do
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: timeline.strand.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      setup_postgres_resource(with_server: false)
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if the private subnet isn't deleted yet" do
      project_id = pgr_test.strand.stack.first["postgres_test_project_id"]
      ps = PrivateSubnet.create(name: "subnet", project_id:, location_id:, net4: "10.0.0.0/26", net6: "fd00::/64")
      refresh_frame(pgr_test, new_values: {"private_subnet_id" => ps.id})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "hops to finish if the postgres resource destroyed" do
      expect { pgr_test.wait_resources_destroyed }.to hop("finish")
    end
  end

  describe "#finish" do
    it "delete project and exits successfully if no failure happened" do
      pgr_test
      expect { pgr_test.finish }.to exit({"msg" => "Postgres tests are finished!"})
        .and change { Project.select_order_map(:name) }.from(["Postgres-Test-Project", "service-project"]).to(["service-project"])
    end

    it "not delete project if Config.local_e2e_postgres_test_project_id" do
      pgr_test
      project = Project.create(name: "foo")
      expect(Config).to receive(:local_e2e_postgres_test_project_id).and_return(project.id).at_least(:once)
      expect { pgr_test.finish }.to exit({"msg" => "Postgres tests are finished!"})
        .and not_change { Project.select_order_map(:name) }
    end

    it "hops to failed if a failure happened" do
      refresh_frame(pgr_test, new_values: {"fail_message" => "Test failed"})
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
