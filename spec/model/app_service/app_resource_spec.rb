# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AppResource do
  subject(:app_resource) {
    described_class.create(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-app",
      repo_url: "https://github.com/owner/repo",
      branch: "main",
    )
  }

  let(:project) { Project.create_with_id(Project.generate_uuid, name: "p") }

  describe "#next_deployment_version" do
    it "returns 1 when there are no deployments" do
      expect(app_resource.next_deployment_version).to eq(1)
    end

    it "returns one past the highest version" do
      AppDeployment.create(app_resource_id: app_resource.id, version: 3, status: "active")
      expect(app_resource.next_deployment_version).to eq(4)
    end
  end

  describe "#latest_deployment" do
    it "returns nil when there are no deployments" do
      expect(app_resource.latest_deployment).to be_nil
    end

    it "returns the highest-version deployment" do
      AppDeployment.create(app_resource_id: app_resource.id, version: 1, status: "superseded")
      latest = AppDeployment.create(app_resource_id: app_resource.id, version: 2, status: "active")
      expect(app_resource.latest_deployment.id).to eq(latest.id)
    end
  end

  describe "#path" do
    it "returns the app path" do
      expect(app_resource.path).to eq("/app/#{app_resource.ubid}")
    end
  end

  describe "#hostname" do
    it "is nil without a load balancer" do
      expect(app_resource.hostname).to be_nil
    end

    it "delegates to the load balancer when present" do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-subnet", location_id: Location::HETZNER_FSN1_ID)
      lb = Prog::Vnet::LoadBalancerNexus.assemble(subnet.id, name: "test-lb", src_port: 80, dst_port: 8080, health_check_protocol: "tcp").subject
      app_resource.update(load_balancer_id: lb.id)
      expect(app_resource.reload.hostname).to eq(lb.hostname)
    end
  end

  describe "#display_state" do
    it "is creating before the strand is waiting" do
      expect(app_resource.display_state).to eq("creating")
    end

    it "is running once the strand is waiting" do
      Strand.create_with_id(app_resource, prog: "AppService::AppResourceNexus", label: "wait")
      expect(app_resource.reload.display_state).to eq("running")
    end

    it "is deleting when the destroy semaphore is set" do
      Strand.create_with_id(app_resource, prog: "AppService::AppResourceNexus", label: "wait")
      app_resource.incr_destroy
      expect(app_resource.reload.display_state).to eq("deleting")
    end
  end

  describe "#deploy" do
    before { Strand.create_with_id(app_resource, prog: "AppService::AppResourceNexus", label: "wait") }

    it "creates the next pending deployment and sets the deploy semaphore" do
      d1 = app_resource.deploy
      expect(d1.version).to eq(1)
      expect(d1.status).to eq("pending")
      expect(Semaphore.where(strand_id: app_resource.id, name: "deploy").count).to eq(1)

      expect(app_resource.deploy.version).to eq(2)
    end
  end

  describe "#scale" do
    before { Strand.create_with_id(app_resource, prog: "AppService::AppResourceNexus", label: "wait") }

    it "creates a new process (defaulting vm_size) and signals convergence" do
      process = app_resource.scale("worker", replica_count: 2)
      expect(process.process_type).to eq("worker")
      expect(process.replica_count).to eq(2)
      expect(process.vm_size).to eq(AppResource::DEFAULT_VM_SIZE)
      expect(Semaphore.where(strand_id: app_resource.id, name: "converge").count).to eq(1)
    end

    it "creates a new process with the given vm_size" do
      process = app_resource.scale("worker", replica_count: 1, vm_size: "standard-8")
      expect(process.vm_size).to eq("standard-8")
    end

    it "updates an existing process" do
      AppProcess.create(app_resource_id: app_resource.id, process_type: "web", replica_count: 1, vm_size: "standard-2")
      process = app_resource.scale("web", replica_count: 4, vm_size: "standard-4")
      expect(process.replica_count).to eq(4)
      expect(process.vm_size).to eq("standard-4")
    end

    it "keeps the existing vm_size when none is given on update" do
      AppProcess.create(app_resource_id: app_resource.id, process_type: "web", replica_count: 1, vm_size: "standard-2")
      process = app_resource.scale("web", replica_count: 2)
      expect(process.vm_size).to eq("standard-2")
    end
  end
end
