# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::PostgresResource do
  subject(:pgr_test) { described_class.new(described_class.assemble) }

  let(:test_project) { Project.create(name: "test-project") }
  let(:service_project) { Project.create(name: "service-project") }
  let(:working_representative_server) { instance_double(PostgresServer, run_query: "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1") }
  let(:faulty_representative_server) { instance_double(PostgresServer, run_query: "") }

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
      expect(pgr_test).to receive(:frame).and_return({"provider" => "metal", "postgres_test_project_id" => test_project.id}).at_least(:once)
      expect { pgr_test.start }.to hop("wait_postgres_resource")
    end

    it "creates resource on aws and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      expect(pgr_test).to receive(:frame).and_return({"provider" => "aws", "postgres_test_project_id" => test_project.id}).at_least(:once)
      expect { pgr_test.start }.to hop("wait_postgres_resource")
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      expect(LocationCredential[location.id].access_key).to eq("access_key")
    end
  end

  describe "#wait_postgres_resource" do
    it "hops to test_basic_connectivity if the postgres resource is ready" do
      expect(pgr_test).to receive(:postgres_resource).exactly(2).and_return(instance_double(Prog::Postgres::PostgresResourceNexus, strand: instance_double(Strand, label: "wait"), representative_server: instance_double(PostgresServer, run_query: "1")))
      expect { pgr_test.wait_postgres_resource }.to hop("test_postgres")
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      expect(pgr_test).to receive(:postgres_resource).exactly(2).and_return(instance_double(Prog::Postgres::PostgresResourceNexus, strand: instance_double(Strand, label: "wait"), representative_server: instance_double(PostgresServer, run_query: "")))
      expect { pgr_test.wait_postgres_resource }.to nap(10)
    end
  end

  describe "#test_postgres" do
    it "fails if the basic connectivity test fails" do
      expect(pgr_test).to receive(:representative_server).and_return(faulty_representative_server)
      expect { pgr_test.test_postgres }.to hop("destroy_postgres")
    end

    it "hops to test_table_create if the basic connectivity test passes" do
      expect(pgr_test).to receive(:representative_server).and_return(working_representative_server)
      expect { pgr_test.test_postgres }.to hop("destroy_postgres")
    end
  end

  describe "#destroy_postgres" do
    it "increments the destroy count and hops to destroy" do
      postgres_resource = instance_double(Prog::Postgres::PostgresResourceNexus, incr_destroy: nil)
      expect(PostgresResource).to receive(:[]).and_return(postgres_resource)
      expect(postgres_resource).to receive(:incr_destroy)
      expect(pgr_test).to receive(:frame).and_return({})
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      expect(pgr_test).to receive(:postgres_resource).and_return(instance_double(PostgresResource))
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if the private subnet isn't deleted yet" do
      expect(pgr_test).to receive(:postgres_resource).and_return(nil)
      expect(PrivateSubnet).to receive(:[]).and_return(instance_double(PrivateSubnet))
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "hops to destroy if the postgres resource destroyed" do
      expect(pgr_test).to receive(:postgres_resource).and_return(nil)
      expect { pgr_test.wait_resources_destroyed }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "increments the destroy count and exits if no failure happened" do
      expect(Project).to receive(:[]).exactly(2).and_return(instance_double(Project, id: "1234", destroy: nil))
      expect(pgr_test).to receive(:frame).exactly(3).and_return({"project_created" => false})
      expect { pgr_test.destroy }.to exit({"msg" => "Postgres tests are finished!"})
    end

    it "increments the destroy count and hops to failed if a failure happened" do
      expect(Project).to receive(:[]).exactly(2).and_return(instance_double(Project, id: "1234", destroy: nil))
      expect(pgr_test).to receive(:frame).exactly(3).and_return({"fail_message" => "Test failed", "project_created" => true})
      expect { pgr_test.destroy }.to hop("failed")
    end
  end

  describe "#failed" do
    it "naps" do
      expect { pgr_test.failed }.to nap(15)
    end
  end

  describe ".representative_server" do
    it "returns the representative server" do
      postgres_resource = instance_double(Prog::Postgres::PostgresResourceNexus, representative_server: working_representative_server)
      expect(pgr_test).to receive(:postgres_resource).and_return(postgres_resource)
      expect(pgr_test.representative_server).to eq(working_representative_server)
    end
  end
end
