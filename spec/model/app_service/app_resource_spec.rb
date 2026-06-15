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
      target_vm_size: "standard-2",
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
end
