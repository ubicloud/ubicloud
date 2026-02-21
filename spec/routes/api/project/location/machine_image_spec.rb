# frozen_string_literal: true

require_relative "../../spec_helper"

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

  let(:stopped_vm) {
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
    vm.strand.update(label: "stopped")
    vm
  }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not get" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{machine_image.name}"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not delete" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{machine_image.name}"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "success get all location machine images" do
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

      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end

    it "success get all project machine images" do
      machine_image

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(1)
    end

    it "success get machine image" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{machine_image.name}"

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["name"]).to eq("test-image")
      expect(parsed["state"]).to eq("available")
    end

    it "success get machine image by ubid" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{machine_image.ubid}"

      expect(last_response.status).to eq(200)
    end

    it "get does not exist for valid name" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/fooname"

      expect(last_response).to have_api_error(404, "Sorry, we couldn\u2019t find the resource you\u2019re looking for.")
    end

    it "success post" do
      vm = stopped_vm

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid,
        description: "My image"
      }.to_json

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["name"]).to eq("my-image")
      expect(parsed["state"]).to eq("creating")
    end

    it "post fails when VM is not stopped" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "running-vm", location_id: Location::HETZNER_FSN1_ID).subject

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "post fails when VM does not exist" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: "vm00000000000000000000000"
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "post fails when VM is in different location" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "other-vm", location_id: Location[name: "hetzner-hel1"].id).subject
      vm.strand.update(label: "stopped")

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "success delete" do
      mi = machine_image
      Strand.create(id: mi.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => mi.id}])

      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.ubid}"

      expect(last_response.status).to eq(204)
    end

    it "delete for non-existant ubid" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{MachineImage.generate_ubid}"

      expect(last_response.status).to eq(204)
    end

    it "can get a public image from another project" do
      other_project = Project.create(name: "other-project")
      public_mi = MachineImage.create(
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

      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{public_mi.ubid}"

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["name"]).to eq("public-image")
    end

    it "location not exist" do
      post "/project/#{project.ubid}/location/not-exist-location/machine-image/test-image", {
        vm_id: "vm00000000000000000000000"
      }.to_json

      expect(last_response).to have_api_error(404, "Validation failed for following path components: location")
    end
  end
end
