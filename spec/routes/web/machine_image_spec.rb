# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "machine_image" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:machine_image) do
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
  end

  let(:mi_wo_permission) {
    MachineImage.create(
      name: "other-image",
      project_id: project_wo_permissions.id,
      location_id: Location::HETZNER_FSN1_ID,
      state: "available",
      s3_bucket: "test-bucket",
      s3_prefix: "images/other/",
      s3_endpoint: "https://r2.example.com",
      size_gib: 10
    )
  }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/machine-image"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no machine images" do
        visit "#{project.path}/machine-image"

        expect(page.title).to eq("Ubicloud - Your Images")
        expect(page).to have_content "No images yet"
      end

      it "can list machine images" do
        machine_image
        visit "#{project.path}/machine-image"

        expect(page.title).to eq("Ubicloud - Your Images")
        expect(page).to have_content machine_image.name
      end

      it "can not list machine images when does not have permissions" do
        machine_image
        mi_wo_permission
        visit "#{project.path}/machine-image"

        expect(page.title).to eq("Ubicloud - Your Images")
        expect(page).to have_content machine_image.name
        expect(page).to have_no_content mi_wo_permission.name
      end
    end

    describe "show" do
      it "can show machine image details" do
        machine_image
        visit "#{project.path}#{machine_image.path}"

        expect(page).to have_content machine_image.name
        expect(page).to have_content machine_image.ubid
      end

      it "raises not found when machine image not exists" do
        visit "#{project.path}/location/eu-central-h1/machine-image/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "delete" do
      it "can delete machine image" do
        mi = machine_image
        Strand.create(id: mi.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => mi.id}])

        visit "#{project.path}#{mi.path}"

        click_button "Delete"
        expect(page).to have_flash_notice("Machine image is being deleted")
        expect(mi.reload.destroy_set?).to be true
      end
    end

    describe "create image from VM" do
      it "can create image from stopped VM" do
        vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
        vm.strand.update(label: "stopped")

        visit "#{project.path}#{vm.path}"

        expect(page).to have_content "Create Image"
        within("#create-image-form") do
          fill_in "name", with: "my-image"
          click_button "Create Image"
        end

        expect(page).to have_flash_notice("'my-image' image is being created")
        mi = MachineImage.where(name: "my-image").first
        expect(mi).not_to be_nil
        expect(mi.project_id).to eq(project.id)
      end

      it "does not show create image for running VM" do
        vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "running-vm", location_id: Location::HETZNER_FSN1_ID).subject

        visit "#{project.path}#{vm.path}"

        expect(page).to have_no_button "Create Image"
      end
    end
  end
end
