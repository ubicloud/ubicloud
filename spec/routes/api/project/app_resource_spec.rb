# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "app" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:app_project) { Project.create_with_id(Project.generate_uuid, name: "app-svc") }

  def assemble_app(name: "my-app")
    Prog::AppService::AppResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name:,
      repo_url: "https://github.com/owner/repo",
      branch: "main",
    ).subject
  end

  describe "unauthenticated" do
    it "cannot list" do
      get "/project/#{project.ubid}/app"
      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
      allow(Config).to receive_messages(app_service_project_id: app_project.id, control_plane_outbound_cidrs: ["172.16.0.0/16"])
    end

    it "lists apps" do
      get "/project/#{project.ubid}/app"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("items" => [])

      assemble_app
      get "/project/#{project.ubid}/app"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].map { it["name"] }).to eq(["my-app"])
    end

    it "creates an app" do
      post "/project/#{project.ubid}/app", {name: "my-app", repo_url: "https://github.com/owner/repo", branch: "dev"}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq("my-app")
      expect(body["branch"]).to eq("dev")
      expect(body["state"]).to eq("creating")
      expect(AppResource.first(project_id: project.id, name: "my-app")).not_to be_nil
    end

    it "creates an app with a default branch" do
      post "/project/#{project.ubid}/app", {name: "defaults", repo_url: "https://github.com/owner/repo"}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["branch"]).to eq("main")
    end

    it "returns a validation error for invalid names" do
      post "/project/#{project.ubid}/app", {name: "Bad Name", repo_url: "https://github.com/owner/repo"}.to_json
      expect(last_response.status).to eq(400)
    end

    it "gets an app with its deployments, by id and by name" do
      app = assemble_app
      AppDeployment.create(app_resource_id: app.id, version: 1, status: "active")

      get "/project/#{project.ubid}/app/#{app.ubid}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq("my-app")
      expect(body["deployments"].map { it["version"] }).to eq([1])

      get "/project/#{project.ubid}/app/my-app"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq(app.ubid)
    end

    it "returns 404 for a missing app" do
      get "/project/#{project.ubid}/app/#{AppResource.generate_ubid}"
      expect(last_response.status).to eq(404)
    end

    it "updates the repo_url without changing the branch" do
      app = assemble_app
      post "/project/#{project.ubid}/app/#{app.ubid}", {repo_url: "https://github.com/new/repo"}.to_json
      expect(last_response.status).to eq(200)
      app.reload
      expect(app.repo_url).to eq("https://github.com/new/repo")
      expect(app.branch).to eq("main")
    end

    it "updates the branch without changing the repo_url" do
      app = assemble_app
      post "/project/#{project.ubid}/app/#{app.ubid}", {branch: "release"}.to_json
      expect(last_response.status).to eq(200)
      app.reload
      expect(app.branch).to eq("release")
      expect(app.repo_url).to eq("https://github.com/owner/repo")
    end

    it "deletes an app" do
      app = assemble_app
      delete "/project/#{project.ubid}/app/#{app.ubid}"
      expect(last_response.status).to eq(204)
      expect(Semaphore.where(strand_id: app.id, name: "destroy").count).to eq(1)
    end

    it "triggers a deployment" do
      app = assemble_app
      post "/project/#{project.ubid}/app/#{app.ubid}/deploy"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["version"]).to eq(1)
      expect(body["status"]).to eq("pending")
      expect(Semaphore.where(strand_id: app.id, name: "deploy").count).to eq(1)
    end

    it "scales a process" do
      app = assemble_app
      post "/project/#{project.ubid}/app/#{app.ubid}/scale", {process_type: "web", replica_count: 3}.to_json
      expect(last_response.status).to eq(200)
      web = JSON.parse(last_response.body)["processes"].find { it["type"] == "web" }
      expect(web["replica_count"]).to eq(3)
      expect(Semaphore.where(strand_id: app.id, name: "converge").count).to eq(1)
    end

    it "returns logs (empty when log aggregation is not enabled)" do
      app = assemble_app
      get "/project/#{project.ubid}/app/#{app.ubid}/logs"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("logs" => [])
    end
  end
end
