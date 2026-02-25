# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "machine_image" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:machine_image) {
    MachineImage.create(
      name: "test-image",
      description: "test desc",
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      state: "available",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com",
      size_gib: 20
    )
  }

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
      MachineImage.create(
        name: "test-image-2",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        state: "available",
        s3_bucket: "test-bucket",
        s3_prefix: "images/test2/",
        s3_endpoint: "https://r2.example.com",
        size_gib: 10
      )

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end

    it "lists images across all locations" do
      machine_image
      MachineImage.create(
        name: "other-location-image",
        project_id: project.id,
        location_id: Location[name: "hetzner-hel1"].id,
        state: "available",
        s3_bucket: "test-bucket",
        s3_prefix: "images/other/",
        s3_endpoint: "https://r2.example.com",
        size_gib: 10
      )

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
      MachineImage.create(
        name: "other-project-image",
        project_id: other_project.id,
        location_id: Location::HETZNER_FSN1_ID,
        state: "available",
        s3_bucket: "test-bucket",
        s3_prefix: "images/other/",
        s3_endpoint: "https://r2.example.com",
        size_gib: 10
      )

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["items"].length).to eq(1)
      expect(parsed["items"][0]["name"]).to eq("test-image")
    end

    it "includes public images from other projects" do
      machine_image
      other_project = Project.create(name: "other-project")
      MachineImage.create(
        name: "public-image",
        project_id: other_project.id,
        location_id: Location::HETZNER_FSN1_ID,
        state: "available",
        visible: true,
        s3_bucket: "b",
        s3_prefix: "p/",
        s3_endpoint: "https://r2.example.com",
        size_gib: 10
      )

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["items"].length).to eq(2)
      names = parsed["items"].map { |i| i["name"] }
      expect(names).to include("test-image", "public-image")
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
