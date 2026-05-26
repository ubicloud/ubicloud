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
  let(:mi_version_metal) { create_machine_image_version_metal(project_id: project.id, location_id:) }
  let(:mi) { mi_version_metal.machine_image_version.machine_image }
  let(:mi_version) { mi_version_metal.machine_image_version }
  let(:empty_mi) { MachineImage.create(project_id: project.id, location_id:, name: "empty-mi", arch: "x64") }

  describe "unauthenticated" do
    it "cannot list without login" do
      visit "/machine-image"
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

      it "hides the sidebar entry when ff_machine_image is disabled" do
        project.set_ff_machine_image(false)
        visit project.path
        expect(page).to have_no_link "Machine Images"
      end

      it "shows the sidebar entry when ff_machine_image is enabled" do
        visit project.path
        expect(page).to have_link "Machine Images", href: "#{project.path}/machine-image"
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
        expect(page).to have_content "No machine images yet"
      end
    end

    describe "overview" do
      it "redirects bare machine image path to the overview tab" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}"
        expect(page).to have_current_path "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/overview"
      end

      it "can be looked up by ubid" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.ubid}/overview"
        expect(page.status_code).to eq(200)
        expect(page).to have_content mi.name
      end

      it "renders the overview tab with the image details" do
        mi.update(latest_version_id: mi_version.id)
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/overview"
        expect(page.title).to eq("Ubicloud - #{mi.name}")
        expect(page).to have_content mi.name
        expect(page).to have_content mi.display_location
        expect(page).to have_content mi.arch
        expect(page).to have_content mi_version.version
      end

      it "returns 404 when machine image is not found" do
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/missing/overview"
        expect(page.status_code).to eq(404)
      end

      it "denies access without MachineImage:view permission" do
        mi_version_metal
        AccessControlEntry.dataset.destroy
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/overview"
        expect(page.status_code).to eq(403)
      end
    end

    describe "versions tab" do
      it "lists the versions" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        expect(page).to have_css "#miv-#{mi_version.ubid}"
        expect(page).to have_content mi_version.version
      end

      it "color-codes a ready version green" do
        mi_version_metal
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{mi_version.ubid}") do
          expect(page).to have_css "span.bg-green-100", text: "ready"
        end
      end

      it "color-codes a creating version yellow" do
        mi_version_metal.update(enabled: false, archive_size_mib: nil)
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{mi_version.ubid}") do
          expect(page).to have_css "span.bg-yellow-100", text: "creating"
        end
      end

      it "color-codes a destroying version red" do
        mi_version_metal.update(enabled: false)
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{mi.name}/versions"
        within("#miv-#{mi_version.ubid}") do
          expect(page).to have_css "span.bg-red-100", text: "destroying"
        end
      end

      it "shows the empty state when the machine image has no versions" do
        visit "#{project.path}/location/#{TEST_LOCATION}/machine-image/#{empty_mi.name}/versions"
        expect(page).to have_content "No versions"
      end
    end
  end
end
