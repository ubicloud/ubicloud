# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "machine-image" do
  let(:user) { create_account }
  let(:project) {
    p = project_with_default_policy(user)
    p.set_ff_machine_image(true)
    p
  }
  let(:location_id) { Location[display_name: TEST_LOCATION].id }
  let(:mi_version_metal) { create_machine_image_version_metal(project_id: project.id, location_id:) }
  let(:mi) { mi_version_metal.machine_image_version.machine_image }
  let(:mi_version) { mi_version_metal.machine_image_version }
  let(:store) { mi_version_metal.store }
  let(:source_vm) { create_archive_ready_vm(project_id: project.id, location_id:) }

  before { login_api }

  describe "feature flag" do
    it "returns 400 when ff_machine_image is disabled" do
      project.set_ff_machine_image(false)
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image"
      expect(last_response).to have_api_error(400, "Machine image feature is not enabled for this project. Contact support to enable it.")
    end
  end

  describe "list" do
    it "returns images in the location" do
      mi_version_metal
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["count"]).to eq(1)
      expect(body["items"][0]["name"]).to eq(mi.name)
      expect(mi.path).to eq("/location/#{TEST_LOCATION}/machine-image/#{mi.name}")
    end
  end

  describe "get" do
    it "returns image by name with versions detail" do
      mi.update(latest_version_id: mi_version.id)
      mi_version_metal.update(enabled: true)
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq(mi.name)
      expect(body["latest_version"]).to eq(mi_version.version)
      expect(body["versions"]).to be_an(Array)
      expect(body["versions"].first["state"]).to eq("available")
    end

    it "returns image by ubid" do
      mi_version_metal
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.ubid}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["name"]).to eq(mi.name)
    end

    it "returns 404 when not found" do
      store
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/missing"
      expect(last_response.status).to eq(404)
    end

    it "reports state as creating when metal is disabled" do
      mi_version_metal.update(enabled: false, archive_size_mib: nil)
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["versions"].first["state"]).to eq("creating")
    end

    it "reports state as creating when version has no metal" do
      empty_mi = MachineImage.create(name: "empty-mi", project_id: project.id, arch: "x64", location_id:)
      MachineImageVersion.create(machine_image_id: empty_mi.id, version: "v-no-metal")
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/empty-mi"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["latest_version"]).to be_nil
      expect(body["versions"].first["state"]).to eq("creating")
    end
  end

  describe "create" do
    it "creates with provided version and destroy_source" do
      store
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: source_vm.ubid, version: "v1.0", destroy_source: true}.to_json
      expect(last_response.status).to eq(200)
      new_mi = MachineImage[name: "new-mi"]
      expect(new_mi).not_to be_nil
      miv = new_mi.versions_dataset.first(version: "v1.0")
      expect(miv).not_to be_nil
      strand = miv.strand
      expect(strand.prog).to eq("MachineImage::VersionMetalNexus")
      expect(strand.stack.first).to include("source_vm_id" => source_vm.id, "destroy_source_after" => true)
    end

    it "creates with default version when not provided" do
      store
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi2",
        {vm: source_vm.ubid}.to_json
      expect(last_response.status).to eq(200)
      new_mi = MachineImage[name: "new-mi2"]
      expect(new_mi).not_to be_nil
      miv = new_mi.versions.first
      expect(miv.version).to match(/\A\d{14}\z/)
      strand = miv.strand
      expect(strand.stack.first["destroy_source_after"]).to be false
    end

    it "returns 400 when source VM is not found" do
      store
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: "vm00000000000000000000000000"}.to_json
      expect(last_response).to have_api_error(400, "Source VM not found")
    end

    it "returns 400 when no machine image store is configured" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: source_vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "No machine image store configured for this location")
    end

    it "returns 400 when machine image with name already exists" do
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}",
        {vm: source_vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Machine image with this name already exists in this location")
    end

    it "returns 400 when version label is invalid" do
      store
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: source_vm.ubid, version: "bad/version"}.to_json
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]["details"]).to have_key("version")
    end

    it "returns 400 when source VM is not a metal VM" do
      store
      vm = create_vm(project_id: project.id, location_id:)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM must be a metal VM")
    end

    it "returns 400 when source VM is not stopped" do
      store
      vm_host = create_vm_host(location_id:)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 50, vm_host_id: vm_host.id)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, location_id:)
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id, vring_workers: 1)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM must be stopped")
    end

    it "returns 400 when source VM has more than one storage volume" do
      store
      source_vm  # ensure it exists
      vol = source_vm.vm_storage_volumes.first
      VmStorageVolume.create(vm_id: source_vm.id, boot: false, size_gib: 5, disk_index: 1,
        storage_device_id: vol.storage_device_id, vhost_block_backend_id: vol.vhost_block_backend_id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k2").id, vring_workers: 1)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: source_vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM must have only one storage volume")
    end

    it "returns 400 when source VM's vhost backend doesn't support archive" do
      store
      vm_host = create_vm_host(location_id:)
      old_vbb = create_vhost_block_backend(version: "v0.3.0", allocation_weight: 0, vm_host_id: vm_host.id)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, location_id:)
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "stopped")
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: old_vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id, vring_workers: 1)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM's vhost block backend must support archive")
    end

    it "returns 400 when source VM has no vhost backend" do
      store
      vm_host = create_vm_host(location_id:)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, location_id:)
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "stopped")
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM's vhost block backend must support archive")
    end

    it "returns 400 when source VM's storage volume is not encrypted" do
      store
      vm_host = create_vm_host(location_id:)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 50, vm_host_id: vm_host.id)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, location_id:)
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "stopped")
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id, vring_workers: 1)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM's storage volume must be encrypted")
    end
  end

  describe "update" do
    it "sets latest_version to the given version" do
      mi_version_metal.update(enabled: true)
      patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}",
        {latest_version: mi_version.version}.to_json
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["latest_version"]).to eq(mi_version.version)
      expect(mi.reload.latest_version_id).to eq(mi_version.id)
    end

    it "unsets latest_version when null is provided" do
      mi_version_metal.update(enabled: true)
      mi.update(latest_version_id: mi_version.id)
      patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}",
        {latest_version: nil}.to_json
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["latest_version"]).to be_nil
      expect(mi.reload.latest_version_id).to be_nil
    end

    it "returns 400 when version is not found" do
      mi_version_metal
      patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}",
        {latest_version: "missing"}.to_json
      expect(last_response).to have_api_error(400, "Version missing not found")
    end

    it "returns 400 when version is not ready" do
      mi_version_metal.update(enabled: false)
      patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}",
        {latest_version: mi_version.version}.to_json
      expect(last_response).to have_api_error(400, "Version #{mi_version.version} is not ready")
    end

    it "returns 400 when version has no metal" do
      no_metal = MachineImageVersion.create(machine_image_id: mi.id, version: "v-no-metal")
      patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}",
        {latest_version: no_metal.version}.to_json
      expect(last_response).to have_api_error(400, "Version v-no-metal is not ready")
    end
  end

  describe "rename" do
    it "renames a machine image" do
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/rename",
        {name: "new-name"}.to_json
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["name"]).to eq("new-name")
      expect(mi.reload.name).to eq("new-name")
    end

    it "returns 400 when name is invalid" do
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/rename",
        {name: "Invalid_Name"}.to_json
      expect(last_response.status).to eq(400)
    end
  end

  describe "delete" do
    it "destroys the machine image when it has no versions" do
      empty_mi = MachineImage.create(name: "empty-mi", project_id: project.id, arch: "x64", location_id:)

      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/empty-mi"

      expect(last_response.status).to eq(204)
      expect(empty_mi.exists?).to be false
    end

    it "returns 400 when versions still exist" do
      mi_version_metal
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
      expect(last_response).to have_api_error(400, "Machine image still has versions; destroy them first")
    end
  end
end
