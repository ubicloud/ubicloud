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
    it "returns 404 when ff_machine_image is disabled" do
      project.set_ff_machine_image(false)
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image"
      expect(last_response.status).to eq(404)
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
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq(mi.name)
      expect(body["latest_version"]).to eq(mi_version.version)
      expect(body["versions"]).to be_an(Array)
      expect(body["versions"].first["state"]).to eq("ready")
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

    it "reports non-ready state from display_state" do
      mi_version_metal.update(enabled: false, archive_size_mib: nil)
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["versions"].first["state"]).to eq("creating")
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
      expect(strand.prog).to eq("MachineImage::CreateVersionMetal")
      expect(strand.stack.first).to eq("source_vm_id" => source_vm.id, "destroy_source_after" => true, "set_as_latest" => true)
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
        {vm: "vm000000000000000000000000"}.to_json
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

    it "returns 400 when source VM is in a different location" do
      store
      other_location = Location.where(display_name: "hetzner-hel1").first || Location[display_name: "eu-north-h1"]
      vm_host = create_vm_host(location_id: other_location.id)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 50, vm_host_id: vm_host.id)
      other_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, location_id: other_location.id, name: "other-loc-vm")
      Strand.create_with_id(other_vm, prog: "Vm::Nexus", label: "stopped")
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: other_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id, vring_workers: 1)

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: other_vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM not found")
    end

    it "rejects when destroy_source is true and the caller lacks permission to destroy the source VM" do
      store
      other_user = create_account("other_user@example.com")
      other_user.add_project(project)
      other_pat = ApiKey.create_personal_access_token(other_user, project:)
      header "Authorization", "Bearer pat-#{other_pat.ubid}-#{other_pat.key}"

      [other_user.id, other_pat.id].each do |sid|
        AccessControlEntry.create(project_id: project.id, subject_id: sid, action_id: ActionType::NAME_MAP["MachineImage:create"])
        AccessControlEntry.create(project_id: project.id, subject_id: sid, action_id: ActionType::NAME_MAP["Vm:view"])
      end

      # fails with destroy_source since other_user doesn't have Vm:delete permission
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: source_vm.ubid, destroy_source: true}.to_json
      expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
    end

    it "falls back to the platform default machine image store" do
      platform_project = Project.create(name: "platform")
      expect(Config).to receive(:machine_images_service_project_id).and_return(platform_project.id).at_least(:once)
      MachineImageStore.create(project_id: platform_project.id, location_id:, provider: "r2", region: "auto",
        endpoint: "https://r2.cloudflare.com/", bucket: "platform", access_key: "ak", secret_key: "sk")

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: source_vm.ubid}.to_json
      expect(last_response.status).to eq(200)
    end

    it "returns 400 when version label is invalid" do
      store
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: source_vm.ubid, version: "bad/version"}.to_json
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]["details"]).to have_key("version")
    end

    it "rejects POST with a UBID in the path (create is name-only)" do
      store
      ubid = "m1n30gjk1d1e2jj34v9x0dq4rp"
      expect {
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{ubid}",
          {vm: source_vm.ubid}.to_json
      }.to raise_error(Committee::InvalidRequest, /does not match/)
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

    it "returns 400 when source VM's storage volume doesn't support machine images" do
      store
      vm_host = create_vm_host(location_id:)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 50, vm_host_id: vm_host.id)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, location_id:)
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "stopped")
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id, vring_workers: 1)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/new-mi",
        {vm: vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM's storage volume doesn't support machine images")
    end

    it "returns 400 when source VM's storage volume is not encrypted" do
      store
      vm_host = create_vm_host(location_id:)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 50, vm_host_id: vm_host.id)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, location_id:)
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "stopped")
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id, vring_workers: 1, track_written: true)
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

    it "rejects PATCH with missing latest_version field (enforced by OpenAPI)" do
      mi
      expect {
        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}", "{}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: latest_version/)
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

    it "rejects rename to an already-taken name with a 400" do
      # pg_auto_constraint_validations turns the unique-index violation into a
      # Sequel::ValidationFailed, mapped to 400 by the error handler.
      MachineImage.create(project_id: project.id, arch: "x64", location_id:, name: "taken-name")
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/rename",
        {name: "taken-name"}.to_json
      expect(last_response.status).to eq(400)
    end

    it "is a no-op when name is unchanged" do
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/rename",
        {name: mi.name}.to_json
      expect(last_response.status).to eq(200)
      expect(mi.reload.name).to eq(mi.name)
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

  describe "version list" do
    it "returns versions for a machine image" do
      mi_version_metal
      MachineImageVersion.create(machine_image_id: mi.id, version: "v-no-metal")
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["count"]).to eq(2)
      with_metal = body["items"].find { |i| i["version"] == mi_version.version }
      expect(with_metal["state"]).to eq("ready")
      no_metal = body["items"].find { |i| i["version"] == "v-no-metal" }
      expect(no_metal["state"]).to be_nil
      expect(no_metal["archive_size_mib"]).to be_nil
    end
  end

  describe "version create" do
    it "creates a new version" do
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/v2",
        {vm: source_vm.ubid, destroy_source: true}.to_json
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["version"]).to eq("v2")
      miv = mi.versions_dataset.first(version: "v2")
      expect(miv).not_to be_nil
      strand = miv.strand
      expect(strand.prog).to eq("MachineImage::CreateVersionMetal")
      expect(strand.stack.first).to eq("source_vm_id" => source_vm.id, "destroy_source_after" => true, "set_as_latest" => true)
    end

    it "returns 400 when source VM is not found" do
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/v2",
        {vm: "vm000000000000000000000000"}.to_json
      expect(last_response).to have_api_error(400, "Source VM not found")
    end

    it "returns 400 when source VM arch does not match" do
      mi_version_metal
      vm = create_vm(project_id: project.id, location_id:, arch: "arm64")
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/v2",
        {vm: vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Source VM arch (arm64) does not match machine image arch (x64)")
    end

    it "returns 400 when no store is configured" do
      empty_mi = MachineImage.create(name: "empty-mi", project_id: project.id, arch: "x64", location_id:)
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{empty_mi.name}/version/v2",
        {vm: source_vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "No machine image store configured for this location")
    end

    it "returns 400 when version already exists" do
      mi_version_metal
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/#{mi_version.version}",
        {vm: source_vm.ubid}.to_json
      expect(last_response).to have_api_error(400, "Version #{mi_version.version} already exists for this machine image")
    end
  end

  describe "version destroy" do
    it "schedules destruction for a non-latest version" do
      mi_version_metal
      extra = MachineImageVersion.create(machine_image_id: mi.id, version: "v2")
      extra_metal = MachineImageVersionMetal.create_with_id(
        extra, archive_kek_id: mi_version_metal.archive_kek_id,
        store_id: mi_version_metal.store_id, store_prefix: "p2", enabled: true, archive_size_mib: 100,
      )
      mi.update(latest_version_id: mi_version.id)

      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/v2"
      expect(last_response.status).to eq(204)
      expect(extra_metal.reload.enabled).to be false
      expect(Strand[extra_metal.id].prog).to eq("MachineImage::DestroyVersionMetal")
    end

    it "returns 400 when version has no metal" do
      mi_version_metal
      MachineImageVersion.create(machine_image_id: mi.id, version: "v-no-metal")
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/v-no-metal"
      expect(last_response).to have_api_error(400, "Version has no metal record to destroy")
    end

    it "returns 400 when version is still being created" do
      mi_version_metal.update(enabled: false, archive_size_mib: nil)
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/#{mi_version.version}"
      expect(last_response).to have_api_error(400, "Version is still being created; wait for it to finish before destroying")
    end

    it "is idempotent when version is already being destroyed" do
      mi_version_metal.update(enabled: false)
      expect {
        delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/#{mi_version.version}"
      }.not_to change { Strand[mi_version_metal.id] }
      expect(last_response.status).to eq(204)
    end

    it "returns 400 when destroying the latest version" do
      mi_version_metal
      mi.update(latest_version_id: mi_version.id)
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/#{mi_version.version}"
      expect(last_response).to have_api_error(400, "Cannot destroy the latest version of a machine image")
    end

    it "returns 404 when version is not found" do
      mi_version_metal
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/missing"
      expect(last_response).to have_api_error(404, "Machine image version not found")
    end

    it "returns 400 when VMs are still using the version" do
      vm_host = create_vm_host
      vhost = create_vhost_block_backend(allocation_weight: 50, vm_host_id: vm_host.id)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vhost.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k1").id,
        machine_image_version_id: mi_version_metal.machine_image_version.id,
        vring_workers: 1,
      )
      extra = MachineImageVersion.create(machine_image_id: mi.id, version: "v2")
      MachineImageVersionMetal.create_with_id(
        extra, archive_kek_id: mi_version_metal.archive_kek_id,
        store_id: mi_version_metal.store_id, store_prefix: "p2", enabled: true, archive_size_mib: 100,
      )
      mi.update(latest_version_id: extra.id)

      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/version/#{mi_version.version}"
      expect(last_response).to have_api_error(400, "VMs are still using this machine image version")
    end
  end
end
