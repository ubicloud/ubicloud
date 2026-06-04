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
  let(:mi_version_metal) { create_machine_image_version_metal(project_id: project.id, location_id:) }
  let(:mi) { mi_version_metal.machine_image_version.machine_image }
  let(:mi_version) { mi_version_metal.machine_image_version }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "#{project.path}/machine-image"
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
  end
end
