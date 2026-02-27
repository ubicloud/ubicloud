# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "machine_image" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  def create_mi(name: "test-image", project_id: nil, location_id: nil, description: "test desc", version_state: "available", size_gib: 20, arch: "arm64", activate: false)
    mi = MachineImage.create(
      name:,
      description:,
      project_id: project_id || project.id,
      location_id: location_id || Location::HETZNER_FSN1_ID,
      arch:
    )
    ver = MachineImageVersion.create(
      machine_image_id: mi.id,
      version: 1,
      state: version_state,
      size_gib:,
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
    ver.activate! if activate
    mi
  end

  let(:machine_image) { create_mi(activate: true) }

  let(:vm_host) { create_vm_host }
  let(:vbb) { VhostBlockBackend.create(version: "v0.4.0", allocation_weight: 100, vm_host_id: vm_host.id) }

  let(:stopped_vm) {
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
    vm.strand.update(label: "stopped")
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, vhost_block_backend_id: vbb.id, vring_workers: 1)
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
      project.set_ff_machine_image(true)
    end

    it "success get all location machine images" do
      machine_image
      create_mi(name: "test-image-2")

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
      expect(parsed["arch"]).to eq("arm64")
    end

    it "success get machine image by ubid" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{machine_image.ubid}"

      expect(last_response.status).to eq(200)
    end

    it "get does not exist for valid name" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/fooname"

      expect(last_response).to have_api_error(404, /Sorry, we couldn.t find the resource you.re looking for/)
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
      expect(parsed["size_gib"]).to eq(20)
      expect(parsed["arch"]).to eq(vm.arch)

      mi = MachineImage.first(name: "my-image")
      expect(mi).not_to be_nil
      expect(mi.arch).to eq(vm.arch)
      ver = mi.versions.first
      expect(ver.state).to eq("creating")
    end

    it "post fails when VM is not stopped" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "running-vm", location_id: Location::HETZNER_FSN1_ID).subject

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "post fails when VM lacks write tracking (no vhost block backend)" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "old-vm", location_id: Location::HETZNER_FSN1_ID).subject
      vm.strand.update(label: "stopped")
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0)

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "post fails when VM has no boot volume" do
      vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "no-boot-vm", location_id: Location::HETZNER_FSN1_ID).subject
      vm.strand.update(label: "stopped")

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
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, vhost_block_backend_id: vbb.id, vring_workers: 1)

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "post fails when boot disk exceeds max size" do
      vm = stopped_vm
      vm.vm_storage_volumes.first.update(size_gib: 9999)
      allow(Config).to receive(:machine_image_max_size_gib).and_return(100)

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/my-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "post fails when another image is being created from VM" do
      vm = stopped_vm
      in_progress_mi = MachineImage.create(
        name: "in-progress",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID
      )
      MachineImageVersion.create(
        machine_image_id: in_progress_mi.id,
        version: 1,
        state: "creating",
        vm_id: vm.id,
        size_gib: 20,
        s3_bucket: "b",
        s3_prefix: "p/",
        s3_endpoint: "https://r2.example.com"
      )

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/another-image", {
        vm_id: vm.ubid
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
    end

    it "returns 404 when feature flag is off" do
      project.set_ff_machine_image(false)

      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image"

      expect(last_response.status).to eq(404)
    end

    it "success delete" do
      mi = machine_image
      ver = mi.versions.first
      Strand.create(id: ver.id, prog: "MachineImage::Nexus", label: "wait", stack: [{"subject_id" => ver.id}])

      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.ubid}"

      expect(last_response.status).to eq(204)
      expect(DB[:audit_log].where(action: "destroy", ubid_type: "m1").count).to eq(1)
    end

    it "delete for non-existant ubid" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{MachineImage.generate_ubid}"

      expect(last_response.status).to eq(204)
    end

    it "location not exist" do
      post "/project/#{project.ubid}/location/not-exist-location/machine-image/test-image", {
        vm_id: "vm00000000000000000000000"
      }.to_json

      expect(last_response).to have_api_error(404, "Validation failed for following path components: location")
    end
  end
end
