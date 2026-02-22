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

    it "can not create without login" do
      visit "/machine-image/create"

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

        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content "No machine images"

        click_link "Create Machine Image"
        expect(page.title).to eq("Ubicloud - Create Machine Image")
      end

      it "can list machine images" do
        machine_image
        visit "#{project.path}/machine-image"

        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content machine_image.name
      end

      it "can not list machine images when does not have permissions" do
        machine_image
        mi_wo_permission
        visit "#{project.path}/machine-image"

        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content machine_image.name
        expect(page).to have_no_content mi_wo_permission.name
      end

      it "only shows Create Machine Image link on empty page if user has MachineImage:create access" do
        visit "#{project.path}/machine-image"
        expect(page.all("a").map(&:text)).to include "Create Machine Image"
        expect(page).to have_content "Get started by creating a new machine image."
        expect(page).to have_no_content "You don't have permission to create machine images."

        AccessControlEntry.dataset.destroy
        page.refresh
        expect(page.all("a").map(&:text)).not_to include "Create Machine Image"
        expect(page).to have_content "You don't have permission to create machine images."
        expect(page).to have_no_content "Get started by creating a new machine image."
      end
    end

    describe "create" do
      it "can create new machine image" do
        vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
        vm.strand.update(label: "stopped")

        visit "#{project.path}/machine-image/create"

        expect(page.title).to eq("Ubicloud - Create Machine Image")
        fill_in "Name", with: "my-image"
        select "stopped-vm", from: "vm_id"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - my-image")
        expect(page).to have_flash_notice("'my-image' is being created")
        expect(MachineImage.count).to eq(1)
        expect(MachineImage.first.project_id).to eq(project.id)
      end

      it "shows cloud-init guidance on create form" do
        vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
        vm.strand.update(label: "stopped")

        visit "#{project.path}/machine-image/create"

        expect(page).to have_content "Before creating an image"
        expect(page).to have_content "Cloud-init will run on VMs launched from this image"
        expect(page).to have_content "/home/ubi"
        expect(page).to have_content "cloud-init clean"
      end

      it "can not create machine image in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/machine-image/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can not create machine image with invalid name" do
        vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
        vm.strand.update(label: "stopped")

        visit "#{project.path}/machine-image/create"

        fill_in "Name", with: "invalid name"
        select "stopped-vm", from: "vm_id"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Machine Image")
        expect(page).to have_content "Name must only contain"
      end
    end

    describe "show" do
      it "can show machine image details" do
        machine_image
        visit "#{project.path}/machine-image"

        expect(page.title).to eq("Ubicloud - Machine Images")
        expect(page).to have_content machine_image.name

        click_link machine_image.name, href: "#{project.path}#{machine_image.path}"

        expect(page.title).to eq("Ubicloud - #{machine_image.name}")
        expect(page).to have_content machine_image.name
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{mi_wo_permission.path}"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can view public image from another project" do
        other_project = Project.create(name: "other-project")
        public_mi = MachineImage.create(
          name: "public-image",
          project_id: other_project.id,
          location_id: Location::HETZNER_FSN1_ID,
          state: "available",
          visible: true,
          s3_bucket: "b",
          s3_prefix: "p/",
          s3_endpoint: "https://r2.example.com",
          size_gib: 10
        )

        visit "#{project.path}#{public_mi.path}/overview"

        expect(page.title).to eq("Ubicloud - #{public_mi.name}")
        expect(page).to have_content public_mi.name
      end

      it "raises not found when machine image not exists" do
        visit "#{project.path}/location/eu-central-h1/machine-image/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "versions" do
      it "can view versions tab" do
        machine_image
        visit "#{project.path}#{machine_image.path}/versions"

        expect(page.title).to eq("Ubicloud - #{machine_image.name}")
        expect(page).to have_content machine_image.version
      end

      it "can set active version" do
        mi = machine_image
        Strand.create(id: mi.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => mi.id}])

        v2 = MachineImage.create(
          name: mi.name, version: "v2", active: false,
          project_id: project.id, location_id: Location::HETZNER_FSN1_ID,
          state: "available", s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 20
        )

        visit "#{project.path}#{mi.path}/versions"

        expect(page).to have_content "v2"
        click_button "Set Active"

        expect(page).to have_flash_notice("Version 'v2' is now the active version")
        expect(v2.reload.active?).to be true
        expect(mi.reload.active?).to be false
      end
    end

    describe "delete" do
      it "can delete machine image" do
        mi = machine_image
        Strand.create(id: mi.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => mi.id}])

        visit "#{project.path}#{mi.path}"
        within("#machine-image-submenu") { click_link "Settings" }

        click_button "Delete"
        expect(page).to have_flash_notice("Machine image is being deleted")
        expect(MachineImage.first.destroy_set?).to be true
      end

      it "can not delete machine image when does not have permissions" do
        Strand.create(id: mi_wo_permission.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => mi_wo_permission.id}])
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["MachineImage:view"])

        visit "#{project_wo_permissions.path}#{mi_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - other-image"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
