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
        expect(page).to have_current_path("#{project.path}/location/#{TEST_LOCATION}/machine-image/new-mi/overview")
        expect(new_mi.versions.count).to eq(1)
        expect(new_mi.versions.first.strand.prog).to eq("MachineImage::CreateVersionMetal")
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
        expect(page).to have_flash_error("Machine image with this name already exists in this location")
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
    end

    describe "delete version" do
      it "destroys a ready, non-latest version" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{mi_version.ubid}") { click_button(class: "delete-btn") }
        expect(page).to have_flash_notice("Version '#{mi_version.version}' is being deleted")
        expect(Strand.where(prog: "MachineImage::DestroyVersionMetal").count).to eq(1)
      end

      it "refuses to delete a version that is not ready" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        mi_version_metal.update(enabled: false, archive_size_mib: nil)
        within("#miv-#{mi_version.ubid}") { click_button(class: "delete-btn") }
        expect(page).to have_flash_error("Version is still being created; wait for it to finish before destroying")
        expect(Strand.where(prog: "MachineImage::DestroyVersionMetal").count).to eq(0)
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
  end
end
