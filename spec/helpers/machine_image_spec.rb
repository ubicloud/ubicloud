# frozen_string_literal: true

require_relative "../routes/api/spec_helper"

RSpec.describe Clover, "machine_image helper" do
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

  before do
    login_api
    header "Host", "api.ubicloud.com"
    header "Content-Type", "application/json"
    header "Accept", "application/json"
  end

  describe "machine_image_list_dataset" do
    let(:other_project) { Project.create(name: "other-proj") }

    it "returns owned images and public images, excludes other-private" do
      machine_image

      MachineImage.create(
        name: "other-private", project_id: other_project.id,
        location_id: Location::HETZNER_FSN1_ID, state: "available",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 10
      )

      MachineImage.create(
        name: "other-public", project_id: other_project.id,
        location_id: Location::HETZNER_FSN1_ID, state: "available", visible: true,
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 10
      )

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      items = JSON.parse(last_response.body)["items"]
      names = items.map { it["name"] }
      expect(names).to include("test-image")
      expect(names).to include("other-public")
      expect(names).not_to include("other-private")
    end
  end

  describe "machine_image_list_api_response" do
    it "returns paginated results with serialized images" do
      machine_image

      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to have_key("items")
      expect(body["items"].first).to have_key("id")
      expect(body["items"].first).to have_key("name")
      expect(body["items"].first).to have_key("state")
    end

    it "filters by location when location is provided" do
      machine_image

      get "/project/#{project.ubid}/location/eu-north-h1/machine-image"

      expect(last_response.status).to eq(200)
      items = JSON.parse(last_response.body)["items"]
      expect(items).to be_empty
    end

    it "returns all locations when no location filter" do
      machine_image

      get "/project/#{project.ubid}/machine-image"

      expect(last_response.status).to eq(200)
      items = JSON.parse(last_response.body)["items"]
      expect(items.length).to eq(1)
    end
  end

  describe "machine_image_post" do
    it "creates a machine image from a stopped VM" do
      vm = stopped_vm
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 30, disk_index: 0)

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid,
        description: "My image"
      }.to_json

      expect(last_response.status).to eq(200)
      parsed = JSON.parse(last_response.body)
      expect(parsed["name"]).to eq("my-image")
      expect(parsed["state"]).to eq("creating")
      expect(parsed["encrypted"]).to be true
      expect(parsed["size_gib"]).to eq(30)
      expect(parsed["arch"]).to eq("x64")

      mi = MachineImage.first(name: "my-image")
      expect(mi.arch).to eq(vm.arch)
    end

    it "fails when VM is not stopped" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "running-vm", location_id: Location::HETZNER_FSN1_ID).subject

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, /Validation failed/)
      body = JSON.parse(last_response.body)
      expect(body.to_s).to include("Current state:")
      expect(body.to_s).to include("Please stop the VM and try again")
    end

    it "fails when VM is in creating state" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "creating-vm", location_id: Location::HETZNER_FSN1_ID).subject
      vm.update(display_state: "creating")

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, /Validation failed/)
      body = JSON.parse(last_response.body)
      expect(body.to_s).to include("Current state: 'creating'")
    end

    it "fails when VM does not exist" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: "vm00000000000000000000000"
      }.to_json

      expect(last_response).to have_api_error(400, /Validation failed/)
    end

    it "fails when VM is in different location" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "other-vm", location_id: Location[name: "hetzner-hel1"].id).subject
      vm.strand.update(label: "stopped")

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, /Validation failed/)
    end

    it "creates image with empty description when not provided" do
      vm = stopped_vm

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response.status).to eq(200)
      mi = MachineImage.first(name: "my-image")
      expect(mi.description).to eq("")
    end

    it "fails when VM boot disk exceeds maximum image size" do
      vm = stopped_vm
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 300, disk_index: 0)

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, /Validation failed/)
      body = JSON.parse(last_response.body)
      expect(body.to_s).to include("exceeds maximum image size")
    end

    it "sets size_gib to 0 when VM has no boot volume" do
      vm = stopped_vm
      VmStorageVolume.where(vm_id: vm.id).destroy

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response.status).to eq(200)
      mi = MachineImage.first(name: "my-image")
      expect(mi.size_gib).to eq(0)
    end
  end
end
