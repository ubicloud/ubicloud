# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "machine_image" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  def create_mi(name: "test-image", project_id: nil, location_id: nil, description: "test desc", version_state: "available", size_gib: 20, arch: "arm64")
    mi = MachineImage.create(
      name:,
      description:,
      project_id: project_id || project.id,
      location_id: location_id || Location::HETZNER_FSN1_ID,
      arch:
    )
    MachineImageVersion.create(
      machine_image_id: mi.id,
      version: 1,
      state: version_state,
      size_gib:,
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
    mi
  end

  let(:machine_image) { create_mi }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/machine-image"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not post" do
      post "/project/#{project.ubid}/machine-image"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
      project.set_ff_machine_image(true)
    end

    it "success get all machine images" do
      machine_image
      create_mi(name: "test-image-2")

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end

    it "lists images across all locations" do
      machine_image
      create_mi(name: "other-location-image", location_id: Location[name: "hetzner-hel1"].id)

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["items"].length).to eq(2)
    end

    it "returns empty list when no images exist" do
      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(0)
    end

    it "does not list images from other projects" do
      machine_image
      other_project = Project.create(name: "other-project")
      create_mi(name: "other-project-image", project_id: other_project.id)

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["items"].length).to eq(1)
      expect(parsed["items"][0]["name"]).to eq("test-image")
    end

    it "does not list project images without MachineImage:view permission" do
      machine_image

      AccessControlEntry.dataset.destroy

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(0)
    end
  end

  describe "feature flag off" do
    before do
      login_api
    end

    it "returns 404 on API when flag is off" do
      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(404)
    end
  end
end
