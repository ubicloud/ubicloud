# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::SetupLogAggregation do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource) }
  let(:st) { described_class.assemble(postgres_resource.id) }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  describe ".assemble" do
    it "creates a strand with no parent" do
      expect(st.prog).to eq("Postgres::SetupLogAggregation")
      expect(st.label).to eq("start")
      expect(st.parent_id).to be_nil
      expect(st.stack[0]["subject_id"]).to eq(postgres_resource.id)
    end
  end

  describe "#before_run" do
    it "pops if the postgres resource is already gone" do
      postgres_resource.destroy
      expect { nx.before_run }.to exit({"msg" => "postgres resource is gone"})
    end

    it "pops if the postgres resource is being destroyed" do
      postgres_resource.incr_destroying
      expect { nx.before_run }.to exit({"msg" => "postgres resource is gone"})
    end

    it "does nothing while the postgres resource is alive" do
      expect { nx.before_run }.not_to exit({"msg" => "postgres resource is gone"})
    end
  end

  describe "#start" do
    it "registers a deadline that pages as a warning, then hops" do
      expect { nx.start }.to hop("setup")
      expect(nx.strand.stack[0]["deadline_target"]).to be_nil
      expect(nx.strand.stack[0]["deadline_page"]).to eq("warning")
      expect(Time.parse(nx.strand.stack[0]["deadline_at"])).to be_within(60).of(Time.now + 60 * 60)
    end
  end

  describe "#setup" do
    it "sets up log aggregation and signals servers to pick up the config" do
      postgres_server

      client = instance_double(Parseable::Client)
      expect(ParseableResource).to receive(:client_for_project).and_return(client)
      expect(client).to receive_messages(create_stream: "test-stream", create_role: "test-role", create_user: "test-parseable-pass")
      expect(client).to receive(:set_retention).with(stream_name: postgres_resource.ubid, duration_days: ParseableResource::LOG_RETENTION_DAYS)

      expect { nx.setup }.to exit({"msg" => "log aggregation setup is complete"})

      expect(postgres_resource.reload.parseable_password).to eq("test-parseable-pass")
      expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "configure_logs").count).to eq(1)
    end

    it "does not signal servers if parseable is not configured in this environment" do
      postgres_server

      expect { nx.setup }.to exit({"msg" => "log aggregation setup is complete"})

      expect(postgres_resource.reload.parseable_password).to be_nil
      expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "configure_logs").count).to eq(0)
    end

    it "does not swallow errors from parseable, so the strand retries" do
      client = instance_double(Parseable::Client)
      expect(ParseableResource).to receive(:client_for_project).and_return(client)
      expect(client).to receive(:create_stream).and_raise(Parseable::Client::Error.new("boom"))

      expect { nx.setup }.to raise_error(Parseable::Client::Error, "boom")
      expect(postgres_resource.reload.parseable_password).to be_nil
    end
  end
end
