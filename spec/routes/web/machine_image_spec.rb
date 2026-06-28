# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "machine-image" do
  let(:user) { create_account }
  let(:project) {
    p = user.create_project_with_default_policy("project-1")
    p.set_ff_machine_image(true)
    p
  }
  let(:location_id) { Location[display_name: TEST_LOCATION].id }
  let(:source_vm) { create_archive_ready_vm(project_id: project.id, location_id:) }
  let(:mi_version_metal) { create_machine_image_version_metal(project_id: project.id, location_id:) }
  let(:mi) { mi_version_metal.machine_image_version.machine_image }
  let(:mi_version) { mi_version_metal.machine_image_version }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "#{project.path}/machine-image"
      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "#{project.path}/machine-image/create"
      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "feature flag" do
      it "returns 404 when ff_machine_image is disabled on the overview page" do
        project.set_ff_machine_image(false)
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/overview"
        expect(page.status_code).to eq(404)
      end
    end

    describe "list" do
      it "can list no machine images" do
        visit "#{project.path}/machine-image"
        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content "No machine images yet"
      end

      it "can list machine images" do
        mi_version_metal
        visit "#{project.path}/machine-image"
        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content mi.name
      end
    end

    describe "overview" do
      it "redirects bare machine image path to the overview tab" do
        mi.update(latest_version_id: mi_version.id)

        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
        expect(page).to have_current_path "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/overview"
        expect(page.title).to eq("Ubicloud - test-mi")
        expect(page).to have_content "test-mi"
        expect(page).to have_content mi.ubid
        expect(page).to have_content mi.location.display_name
        expect(page).to have_content mi.arch
        expect(page).to have_content "Latest Version"
        expect(page).to have_content mi_version.version
      end

      it "returns 404 when machine image is not found" do
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/missing/overview"
        expect(page.status_code).to eq(404)
      end
    end

    describe "rename" do
      it "can rename machine image" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/settings"
        fill_in "name", with: "Invalid Name"
        click_button "Rename"
        expect(page).to have_flash_error("Validation failed for following fields: name")
        expect(mi.refresh.name).not_to eq("Invalid Name")

        fill_in "name", with: "renamed-mi"
        click_button "Rename"
        expect(page).to have_flash_notice("Name updated")
        expect(mi.refresh.name).to eq("renamed-mi")
      end
    end

    describe "create" do
      let(:view_only_user) {
        u = create_account("other@example.com", with_project: false)
        u.add_project(project)
        AccessControlEntry.create(project_id: project.id, subject_id: u.id, action_id: ActionType::NAME_MAP["MachineImage:view"])
        u
      }

      it "creates a machine image from a stopped VM" do
        MachineImageStore.create(project_id: project.id, location_id:, provider: "r2", region: "auto",
          endpoint: "https://r2.cloudflare.com/", bucket: "test-bucket", access_key: "ak", secret_key: "sk")
        source_vm
        visit "#{project.path}/machine-image/create"
        fill_in "Name", with: "new-mi"
        choose option: Location::HETZNER_FSN1_UBID
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page.status_code).to eq(200)
        new_mi = MachineImage[name: "new-mi"]
        expect(new_mi).not_to be_nil
        expect(page).to have_current_path("#{project.path}/location/#{TEST_LOCATION}/machine-image/new-mi/versions")
        expect(new_mi.versions.count).to eq(1)
        expect(new_mi.versions.first.strand.prog).to eq("MachineImage::VersionMetalNexus")
      end

      it "allows a view-only user to see a machine image but not create one" do
        mi_version_metal
        click_button "Log out"

        login(view_only_user.email)

        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/overview"
        expect(page.status_code).to eq(200)
        expect(page).to have_content mi.name
        expect(page).to have_content mi.ubid

        visit "#{project.path}/machine-image/create"
        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
      end

      it "allows a view-only user to see the machine image but not edit it" do
        mi.update(latest_version_id: mi_version.id)

        click_button "Log out"
        login(view_only_user.email)

        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/overview"
        expect(page.status_code).to eq(200)
        expect(page).to have_content mi.name
        expect(page).to have_content mi.ubid
        expect(page).to have_content "Latest Version"
        expect(page).to have_content mi_version.version

        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/settings"
        expect(page.status_code).to eq(200)
        expect(page).to have_no_content "Rename"
        expect(page).to have_no_content "Latest Version"
        expect(page).to have_no_content "Save"
        expect(page).to have_no_content "Delete Machine Image"
      end

      it "can not create machine image with invalid name" do
        source_vm
        visit "#{project.path}/machine-image/create"
        fill_in "Name", with: "Invalid Name"
        choose option: Location::HETZNER_FSN1_UBID
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page.title).to eq("Ubicloud - Create Machine Image")
        expect(page).to have_content "Name must only contain"
      end

      it "can not create machine image with same name" do
        mi_version_metal
        source_vm
        visit "#{project.path}/machine-image/create"
        fill_in "Name", with: mi.name
        choose option: Location::HETZNER_FSN1_UBID
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page).to have_flash_error("Machine image with this name already exists in this project")
      end

      it "excludes ineligible VMs from the source VM dropdown" do
        source_vm

        non_metal_vm = create_vm(project_id: project.id, location_id:, name: "non-metal-vm")
        Strand.create_with_id(non_metal_vm, prog: "Vm::Nexus", label: "stopped")

        multi_volume_vm = create_archive_ready_vm(project_id: project.id, location_id:, name: "multi-volume-vm")
        sv = multi_volume_vm.vm_storage_volumes.first
        VmStorageVolume.create(
          vm_id: multi_volume_vm.id, boot: false, size_gib: 5, disk_index: 1,
          storage_device_id: sv.storage_device_id, vhost_block_backend_id: sv.vhost_block_backend_id,
          key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "extra").id,
          vring_workers: 1, track_written: true,
        )

        untracked_vm = create_archive_ready_vm(project_id: project.id, location_id:, name: "untracked-vm")
        untracked_vm.vm_storage_volumes.first.update(track_written: false)

        unencrypted_vm = create_archive_ready_vm(project_id: project.id, location_id:, name: "unencrypted-vm")
        unencrypted_vm.vm_storage_volumes.first.update(key_encryption_key_1_id: nil)

        oversized_vm = create_archive_ready_vm(project_id: project.id, location_id:, name: "oversized-vm")
        oversized_vm.vm_storage_volumes.first.update(size_gib: Config.machine_image_max_size_gib + 1)

        visit "#{project.path}/machine-image/create"
        expect(page).to have_select("vm", with_options: [source_vm.name])
        [non_metal_vm, multi_volume_vm, untracked_vm, unencrypted_vm, oversized_vm].each do |ineligible|
          expect(page).to have_no_select("vm", with_options: [ineligible.name])
        end
      end
    end

    describe "create version" do
      it "creates a new version with destroy_source defaulting to false" do
        mi_version_metal
        source_vm
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/create-version"
        fill_in "Version Label", with: "v2"
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page).to have_current_path("#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions")
        expect(page).to have_flash_notice("Version 'v2' is being created")
        miv = mi.versions_dataset.first(version: "v2")
        expect(miv).not_to be_nil
        expect(miv.strand.stack.first["destroy_source_after"]).to be false
      end

      it "excludes VMs whose arch differs from the machine image from the source VM dropdown" do
        mi_version_metal
        source_vm
        wrong_arch_vm = create_archive_ready_vm(project_id: project.id, location_id:, name: "arm64-vm", arch: "arm64")
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/create-version"
        expect(page).to have_select("vm", with_options: [source_vm.name])
        expect(page).to have_no_select("vm", with_options: [wrong_arch_vm.name])
      end
    end

    describe "delete version" do
      let(:args) { {machine_image_id: mi.id, project_id: project.id, machine_image_store_id: mi_version_metal.store_id} }

      it "schedules destruction for a non-latest version" do
        mi_version_metal
        other_metal = create_machine_image_version_metal(**args, version: "v2", store_prefix: "p2")
        other_version = other_metal.machine_image_version
        mi.update(latest_version_id: mi_version.id)
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{other_version.ubid}") do
          expect(page).to have_no_content "(latest)"
          click_button(class: "delete-btn")
        end
        expect(page).to have_flash_notice("Version '#{other_version.version}' is being deleted")
        expect(other_metal.destroy_set?).to be true
      end

      it "schedules destruction for the latest version" do
        mi_version_metal
        mi.update(latest_version_id: mi_version.id)
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{mi_version.ubid}") do
          expect(page).to have_content "(latest)"
          click_button(class: "delete-btn")
        end
        expect(page).to have_flash_notice("Version '#{mi_version.version}' is being deleted")
        expect(mi_version_metal.destroy_set?).to be true
      end

      it "shows the delete button for a creating version" do
        mi_version_metal.update(status: "creating", archive_size_mib: nil)
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{mi_version.ubid}") { click_button(class: "delete-btn") }
        expect(page).to have_flash_notice("Version '#{mi_version.version}' is being deleted")
        expect(mi_version_metal.destroy_set?).to be true
      end

      it "hides the delete button for a version that is already being destroyed" do
        mi_version_metal.update(status: "destroying")
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{mi_version.ubid}") do
          expect(page).to have_no_button(class: "delete-btn")
        end
      end
    end

    describe "destroy machine image" do
      it "refuses to destroy a machine image that still has versions" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/settings"
        within("#mi-delete-#{mi.ubid}") { click_button "Delete Machine Image" }
        expect(page).to have_flash_error("Machine image still has versions; destroy them first")
        expect(MachineImage[mi.id]).not_to be_nil
      end

      it "destroys a machine image with no versions" do
        empty_mi = MachineImage.create(project_id: project.id, location_id:, name: "empty-mi", arch: "x64")
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{empty_mi.name}/settings"
        within("#mi-delete-#{empty_mi.ubid}") { click_button "Delete Machine Image" }
        expect(page).to have_flash_notice("Machine image '#{empty_mi.name}' is deleted")
        expect(MachineImage[empty_mi.id]).to be_nil
      end
    end

    describe "set latest version" do
      it "sets the latest version" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/settings"
        within("#set-latest-version") do
          select mi_version.version, from: "latest_version"
          click_button "Save"
        end
        expect(page).to have_flash_notice("Latest version updated")
        expect(mi.refresh.latest_version_id).to eq(mi_version.id)
      end

      it "refuses to set latest to a non-existent version" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/settings"
        mi_version_metal.destroy
        mi_version.destroy
        within("#set-latest-version") do
          select mi_version.version, from: "latest_version"
          click_button "Save"
        end
        expect(page).to have_flash_error("Version #{mi_version.version} not found")
        expect(mi.refresh.latest_version_id).to be_nil
      end

      it "refuses to set latest to a non-ready version" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/settings"
        mi_version_metal.update(status: "destroying")
        within("#set-latest-version") do
          select mi_version.version, from: "latest_version"
          click_button "Save"
        end
        expect(page).to have_flash_error("Version #{mi_version.version} is not ready")
        expect(mi.refresh.latest_version_id).to be_nil
      end
    end
  end
end
