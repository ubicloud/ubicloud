# frozen_string_literal: true

require "spec_helper"

RSpec.describe MetricsTargetResource do
  subject(:resource) {
    described_class.new(postgres_server)
  }

  let(:postgres_server) {
    PostgresServer.create(
      timeline:, resource: postgres_resource, vm_id: vm.id, is_representative: true,
      synchronization_status: "ready", timeline_access: "push", version: "16"
    )
  }

  let(:project) { Project.create(name: "postgres-server") }
  let(:project_service) { Project.create(name: "postgres-service") }

  let(:timeline) { create_postgres_timeline(location_id: location.id) }

  let(:postgres_resource) { create_postgres_resource(project:, location_id: location.id) }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "postgres-subnet", project:, location:,
      net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
      net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64")
    )
  }

  let(:vm) { create_hosted_vm(project, private_subnet, "dummy-vm") }

  let(:location) {
    Location.create(
      name: "us-west-2",
      project:,
      display_name: "us-west-2",
      ui_name: "us-west-2",
      provider: "ubicloud",
      visible: true
    )
  }

  def create_victoria_metrics_setup(project)
    ps = PrivateSubnet.create(name: "test-ps", project:, location_id: Location::HETZNER_FSN1_ID,
      net4: "10.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64")
    vm = Prog::Vm::Nexus.assemble_with_sshable(project.id, name: "test-vm", private_subnet_id: ps.id,
      location_id: Location::HETZNER_FSN1_ID).subject
    vmr = VictoriaMetricsResource.create(project:, location_id: Location::HETZNER_FSN1_ID,
      name: "test-vmr", admin_user: "admin", admin_password: "pass", target_vm_size: "standard-2",
      target_storage_size_gib: 100, root_cert_1: "cert")
    VictoriaMetricsServer.create(resource: vmr, vm:, cert: "cert", cert_key: "key")
    vmr
  end

  describe "#initialize" do
    before do
      allow(Config).to receive(:victoria_metrics_service_project_id).and_return("4d8f9896-26a3-4784-8f52-2ed5d5e55c0e")
    end

    it "initializes with a resource and nil tsdb client when VictoriaMetrics is not found" do
      expect(Config).to receive(:postgres_service_project_id).and_return("4d8f9896-26a3-4784-8f52-2ed5d5e55c0e")
      expect(resource.instance_variable_get(:@resource)).to eq(postgres_server)
      expect(resource.instance_variable_get(:@tsdb_client)).to be_nil
    end

    it "initializes with a resource and a tsdb client when VictoriaMetrics is found using postgres_service_project_id" do
      prj = Project.create(name: "pg-project")
      expect(Config).to receive(:postgres_service_project_id).at_least(:once).and_return(prj.id)
      create_victoria_metrics_setup(prj)
      expect(VictoriaMetrics::Client).to receive(:new).and_return("tsdb_client")

      expect(resource.instance_variable_get(:@resource)).to eq(postgres_server)
      expect(resource.instance_variable_get(:@tsdb_client)).to eq("tsdb_client")
    end

    it "initializes with a resource and a tsdb client when VictoriaMetrics is found using victoria_metrics_service_project_id" do
      prj = Project.create(name: "vm-project")
      expect(Config).to receive(:postgres_service_project_id).at_least(:once).and_return(nil)
      expect(Config).to receive(:victoria_metrics_service_project_id).at_least(:once).and_return(prj.id)
      create_victoria_metrics_setup(prj)
      expect(VictoriaMetrics::Client).to receive(:new).and_return("tsdb_client")

      expect(resource.instance_variable_get(:@resource)).to eq(postgres_server)
      expect(resource.instance_variable_get(:@tsdb_client)).to eq("tsdb_client")
    end

    it "initializes with a resource and a tsdb client when VictoriaMetrics is not found in development" do
      pg_prj = Project.create(name: "pg-project")
      vm_prj = Project.create(name: "vm-project")
      expect(Config).to receive(:development?).and_return(true)
      expect(Config).to receive(:postgres_service_project_id).at_least(:once).and_return(pg_prj.id)
      expect(Config).to receive(:victoria_metrics_service_project_id).at_least(:once).and_return(vm_prj.id)
      expect(VictoriaMetrics::Client).to receive(:new).with(endpoint: "http://localhost:8428").and_return("tsdb_client")
      expect(resource.instance_variable_get(:@resource)).to eq(postgres_server)
      expect(resource.instance_variable_get(:@tsdb_client)).to eq("tsdb_client")
      expect(resource.instance_variable_get(:@deleted)).to be(false)
    end
  end

  describe "#open_resource_session" do
    it "opens a resource session if not already open" do
      expect(postgres_server).to receive(:init_metrics_export_session).and_return("session")
      resource.open_resource_session
      expect(resource.instance_variable_get(:@session)).to eq("session")
    end

    it "doesn't reopen a session if already open and last export was successful" do
      resource.instance_variable_set(:@session, "session")
      resource.instance_variable_set(:@last_export_success, true)

      # Ensure postgres_server doesn't receive init_metrics_export_session again
      expect(postgres_server).not_to receive(:init_metrics_export_session)

      resource.open_resource_session
      expect(resource.instance_variable_get(:@session)).to eq("session")
    end

    it "marks resource as deleted when Sequel::NoExistingObject is raised" do
      postgres_server.destroy
      expect(Clog).to receive(:emit).with("Resource is deleted.", instance_of(Hash)).and_call_original

      resource.open_resource_session
      expect(resource.instance_variable_get(:@deleted)).to be true
      expect(resource.instance_variable_get(:@session)).to be_nil
    end

    it "raises the exception if it is not Sequel::NoExistingObject" do
      expect(postgres_server).to receive(:reload).and_raise(StandardError)
      expect { resource.open_resource_session }.to raise_error(StandardError)
    end
  end

  describe "#export_metrics" do
    before do
      prj = Project.create(name: "vm-project")
      expect(Config).to receive(:postgres_service_project_id).and_return(prj.id)
      create_victoria_metrics_setup(prj)
      expect(VictoriaMetrics::Client).to receive(:new).and_return("tsdb_client")
    end

    it "calls export_metrics on the resource and updates last_export_success" do
      resource.instance_variable_set(:@session, "session")
      expect(postgres_server).to receive(:export_metrics).with(session: "session", tsdb_client: "tsdb_client")
      expect { resource.export_metrics }.to change { resource.instance_variable_get(:@last_export_success) }.from(false).to(true)
    end

    it "swallows exceptions and logs them" do
      expect(postgres_server).to receive(:export_metrics).and_raise(StandardError.new("Export failed"))
      expect(Clog).to receive(:emit).and_call_original
      expect { resource.export_metrics }.not_to raise_error
    end

    it "skips export if resource is deleted" do
      resource.instance_variable_set(:@deleted, true)
      expect(postgres_server).not_to receive(:export_metrics)
      expect { resource.export_metrics }.not_to raise_error
    end
  end

  describe "#close_resource_session" do
    it "returns if session is nil" do
      resource.instance_variable_set(:@session, nil)
      expect { resource.close_resource_session }.not_to raise_error
    end

    it "closes the session and sets it to nil" do
      session = Net::SSH::Connection::Session.allocate
      resource.instance_variable_set(:@session, {ssh_session: session})
      expect(session).to receive(:shutdown!)
      expect(session).to receive(:close)
      expect { resource.close_resource_session }.to change { resource.instance_variable_get(:@session) }.from({ssh_session: session}).to(nil)
    end
  end
end
