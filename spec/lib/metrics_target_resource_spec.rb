# frozen_string_literal: true

require "spec_helper"

RSpec.describe MetricsTargetResource do
  let(:postgres_server) { PostgresServer.new { it.id = "c068cac7-ed45-82db-bf38-a003582b36ee" } }
  let(:resource) { described_class.new(postgres_server) }

  describe "#initialize" do
    it "initializes with a resource and nil tsdb client when VictoriaMetrics is not found" do
      expect(Config).to receive(:postgres_service_project_id).and_return("4d8f9896-26a3-4784-8f52-2ed5d5e55c0e")
      expect(resource.instance_variable_get(:@resource)).to eq(postgres_server)
    end

    it "initializes with a resource and a tsdb client when VictoriaMetrics is found" do
      expect(Config).to receive(:postgres_service_project_id).at_least(:once).and_return("4d8f9896-26a3-4784-8f52-2ed5d5e55c0e")
      prj = Project.create_with_id(name: "pg-project") { it.id = Config.postgres_service_project_id }
      vmr = instance_double(VictoriaMetricsResource, project_id: prj.id)
      expect(VictoriaMetricsResource).to receive(:first).with(project_id: prj.id).and_return(vmr)
      expect(vmr).to receive(:servers).and_return([instance_double(VictoriaMetricsServer, client: "tsdb_client")])

      expect(resource.instance_variable_get(:@resource)).to eq(postgres_server)
      expect(resource.instance_variable_get(:@tsdb_client)).to eq("tsdb_client")
    end

    it "initializes with a resource and a tsdb client when VictoriaMetrics is not found in development" do
      expect(Config).to receive(:development?).and_return(true)
      expect(Config).to receive(:postgres_service_project_id).at_least(:once).and_return("4d8f9896-26a3-4784-8f52-2ed5d5e55c0e")
      prj = Project.create_with_id(name: "pg-project") { it.id = Config.postgres_service_project_id }
      expect(VictoriaMetricsResource).to receive(:first).with(project_id: prj.id).and_return(nil)
      expect(VictoriaMetrics::Client).to receive(:new).with(endpoint: "http://localhost:8428").and_return("tsdb_client")
      expect(resource.instance_variable_get(:@resource)).to eq(postgres_server)
      expect(resource.instance_variable_get(:@tsdb_client)).to eq("tsdb_client")
      expect(resource.instance_variable_get(:@deleted)).to be(false)
    end
  end

  describe "#open_resource_session" do
    it "opens a resource session if not already open" do
      expect(postgres_server).to receive(:reload).and_return(postgres_server)
      expect(postgres_server).to receive(:init_metrics_export_session).and_return("session")
      resource.open_resource_session
      expect(resource.instance_variable_get(:@session)).to eq("session")
    end

    it "doesn't reopen a session if already open and last export was successful" do
      resource.instance_variable_set(:@session, "session")
      resource.instance_variable_set(:@last_export_success, true)

      # Ensure postgres_server doesn't receive init_metrics_export_session again
      expect(postgres_server).not_to receive(:reload)
      expect(postgres_server).not_to receive(:init_metrics_export_session)

      resource.open_resource_session
      expect(resource.instance_variable_get(:@session)).to eq("session")
    end

    it "marks resource as deleted when Sequel::NoExistingObject is raised" do
      expect(postgres_server).to receive(:reload).and_raise(Sequel::NoExistingObject)

      expect(Clog).to receive(:emit).with("Resource is deleted.").and_yield

      resource.open_resource_session
      expect(resource.deleted).to be true
      expect(resource.instance_variable_get(:@session)).to be_nil
    end

    it "ignores other exceptions" do
      expect(postgres_server).to receive(:reload).and_raise(StandardError)
      expect { resource.open_resource_session }.not_to raise_error
    end
  end

  describe "#export_metrics" do
    before do
      prj = Project.create_with_id(name: "vm-project") { it.id = "4d8f9896-26a3-4784-8f52-2ed5d5e55c0d" }
      expect(Config).to receive(:postgres_service_project_id).and_return(prj.id)
      vmr = instance_double(VictoriaMetricsResource, project_id: prj.id)
      expect(VictoriaMetricsResource).to receive(:first).with(project_id: prj.id).and_return(vmr)
      expect(vmr).to receive(:servers).and_return([instance_double(VictoriaMetricsServer, client: "tsdb_client")])
    end

    it "calls export_metrics on the resource and updates last_export_success" do
      resource.instance_variable_set(:@session, "session")
      expect(postgres_server).to receive(:export_metrics).with(session: "session", tsdb_client: "tsdb_client")
      expect { resource.export_metrics }.to change { resource.instance_variable_get(:@last_export_success) }.from(false).to(true)
    end

    it "swallows exceptions and logs them" do
      expect(postgres_server).to receive(:export_metrics).and_raise(StandardError.new("Export failed"))
      expect(Clog).to receive(:emit)
      expect { resource.export_metrics }.not_to raise_error
    end
  end

  describe "#close_resource_session" do
    it "returns if session is nil" do
      resource.instance_variable_set(:@session, nil)
      expect { resource.close_resource_session }.not_to raise_error
    end

    it "closes the session and sets it to nil" do
      session = instance_double(Net::SSH::Connection::Session)
      resource.instance_variable_set(:@session, {ssh_session: session})
      expect(session).to receive(:shutdown!)
      expect(session).to receive(:close)
      expect { resource.close_resource_session }.to change { resource.instance_variable_get(:@session) }.from({ssh_session: session}).to(nil)
    end
  end

  describe "#force_stop_if_stuck" do
    it "does nothing if pulse check is not stuck" do
      expect(Kernel).not_to receive(:exit!)

      # not locked
      resource.force_stop_if_stuck

      # not timed out
      resource.instance_variable_get(:@mutex).lock
      resource.instance_variable_set(:@export_started_at, Time.now)
      resource.force_stop_if_stuck
      resource.instance_variable_get(:@mutex).unlock
    end

    it "triggers Kernel.exit if pulse check is stuck" do
      resource.instance_variable_get(:@mutex).lock
      resource.instance_variable_set(:@export_started_at, Time.now - 200)
      expect(Clog).to receive(:emit).at_least(:once)
      resource.force_stop_if_stuck
      resource.instance_variable_get(:@mutex).unlock
    end
  end

  describe "#lock_no_wait" do
    it "does not yield if mutex is locked" do
      resource.instance_variable_get(:@mutex).lock
      expect { |b| resource.lock_no_wait(&b) }.not_to yield_control
      resource.instance_variable_get(:@mutex).unlock
    end

    it "yields if mutex is not locked" do
      expect { |b| resource.lock_no_wait(&b) }.to yield_control
    end
  end
end
