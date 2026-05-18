# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "machine-image" do
  let(:user) { create_account }
  let(:project) {
    p = user.create_project_with_default_policy("project-1")
    p.set_ff_machine_image(true)
    p
  }
  let(:location_id) { Location[display_name: TEST_LOCATION].id }
  let(:store) {
    MachineImageStore.create(project_id: project.id, location_id:, provider: "r2", region: "auto",
      endpoint: "https://r2.cloudflare.com/", bucket: "test-bucket", access_key: "ak", secret_key: "sk")
  }
  let(:mi_version_metal) { create_machine_image_version_metal(project_id: project.id, location_id:) }
  let(:mi) { mi_version_metal.machine_image_version.machine_image }
  let(:mi_version) { mi_version_metal.machine_image_version }
  let(:source_vm) { create_archive_ready_vm(project_id: project.id, location_id:) }

  describe "unauthenticated" do
    it "cannot list without login" do
      visit "/machine-image"
      expect(page.title).to eq("Ubicloud - Login")
    end

    it "cannot create without login" do
      visit "/machine-image/create"
      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "feature flag" do
      it "returns 404 when ff_machine_image is disabled" do
        project.set_ff_machine_image(false)
        visit "#{project.path}/machine-image"
        expect(page.status_code).to eq(404)
      end
    end

    describe "list" do
      it "can list machine images" do
        mi_version_metal
        visit "#{project.path}/machine-image"
        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content mi.name
      end

      it "shows empty state when there are no images" do
        visit "#{project.path}/machine-image"
        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content "No machine images"
      end
    end

    describe "show" do
      it "can show machine image details" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
        expect(page.title).to eq("Ubicloud - #{mi.name}")
        expect(page).to have_content mi.name
        expect(page).to have_content mi_version.version
      end

      it "returns 404 for non-existent image" do
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/nonexistent"
        expect(page.status_code).to eq(404)
      end

      it "supports lookup by ubid" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.ubid}"
        expect(page.title).to eq("Ubicloud - #{mi.name}")
      end
    end

    describe "create" do
      it "can show create form" do
        visit "#{project.path}/machine-image/create"
        expect(page.title).to eq("Ubicloud - Create Machine Image")
      end

      it "creates a machine image from a stopped VM" do
        store
        source_vm
        visit "#{project.path}/machine-image/create"
        fill_in "Name", with: "new-mi"
        choose option: Location::HETZNER_FSN1_UBID
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page.status_code).to eq(200)
        new_mi = MachineImage[name: "new-mi"]
        expect(new_mi).not_to be_nil
        expect(page).to have_current_path("#{project.path}/location/#{TEST_LOCATION}/machine-image/new-mi")
        expect(new_mi.versions.count).to eq(1)
        expect(new_mi.versions.first.strand.prog).to eq("MachineImage::CreateVersionMetal")
      end

      it "rejects creation when a machine image with the same name already exists in the location" do
        mi_version_metal
        source_vm
        visit "#{project.path}/machine-image/create"
        fill_in "Name", with: mi.name
        choose option: Location::HETZNER_FSN1_UBID
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page).to have_flash_error "Machine image with this name already exists in this location"
      end

      it "rejects creation with an invalid name" do
        store
        source_vm
        visit "#{project.path}/machine-image/create"
        fill_in "Name", with: "Invalid Name"
        choose option: Location::HETZNER_FSN1_UBID
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page).to have_flash_error("Validation failed for following fields: name")
      end
    end

    describe "create-version" do
      it "can show create-version form" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/create-version"
        expect(page.title).to eq("Ubicloud - Create Version — #{mi.name}")
      end

      it "creates a new version of an existing machine image" do
        mi_version_metal
        source_vm
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/create-version"
        fill_in "Version Label", with: "v2"
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page.status_code).to eq(200)
        miv = mi.versions_dataset.first(version: "v2")
        expect(miv).not_to be_nil
        expect(miv.strand.prog).to eq("MachineImage::CreateVersionMetal")
      end

      it "rejects a duplicate version label" do
        mi_version_metal
        source_vm
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/create-version"
        fill_in "Version Label", with: mi_version.version
        select source_vm.name, from: "vm"
        click_button "Create"
        expect(page).to have_flash_error("Version #{mi_version.version} already exists")
      end

      it "redirects unauthorized users away from the create-version form" do
        mi_version_metal
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["MachineImage:view"])
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/create-version"
        expect(page.status_code).to eq(403)
      end
    end

    describe "delete" do
      it "can delete machine image with no versions" do
        mi_version_metal
        mi_name = mi.name
        mi.update(latest_version_id: nil)
        mi_version_metal.destroy
        mi_version.destroy
        mi.refresh

        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi_name}"
        click_button "Delete Machine Image"
        expect(page).to have_current_path("#{project.path}/machine-image")
        expect(MachineImage.where(id: mi.id).any?).to be false
      end

      it "rejects deletion while versions exist and flashes an error" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
        click_button "Delete Machine Image"
        expect(page).to have_flash_error "Machine image still has versions; destroy them first"
        expect(MachineImage.where(id: mi.id).any?).to be true
      end
    end
  end
end
