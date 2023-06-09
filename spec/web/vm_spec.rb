# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:tag_space) { user.create_tag_space_with_default_policy("tag-space-1") }

  let(:tag_space_wo_permissions) { user.create_tag_space_with_default_policy("tag-space-2", policy_body: []) }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public-key", tag_space.id, name: "dummy-vm-1").vm
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  let(:vm_wo_permission) { Prog::Vm::Nexus.assemble("dummy-public-key", tag_space_wo_permissions.id, name: "dummy-vm-2").vm }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/vm"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/vm/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no virtual machines" do
        visit "/vm"

        expect(page.title).to eq("Ubicloud - Virtual Machines")
        expect(page).to have_content "No virtual machines"

        click_link "New Virtual Machine"
        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
      end

      it "can not list virtual machines when does not have permissions" do
        vm
        vm_wo_permission
        visit "/vm"

        expect(page.title).to eq("Ubicloud - Virtual Machines")
        expect(page).to have_content vm.name
        expect(page).not_to have_content vm_wo_permission.name
      end
    end

    describe "create" do
      it "can create new virtual machine" do
        tag_space
        visit "/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        select tag_space.name, from: "tag-space-id"
        choose option: "hetzner-hel1"
        choose option: "ubuntu-jammy"
        choose option: "c5a.2x"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(Vm.count).to eq(1)
      end

      it "can not create virtual machine with invalid name" do
        tag_space
        visit "/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        fill_in "Name", with: "invalid name"
        select tag_space.name, from: "tag-space-id"
        choose option: "hetzner-hel1"
        choose option: "ubuntu-jammy"
        choose option: "c5a.2x"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not select tag space when does not have permissions" do
        tag_space
        tag_space_wo_permissions
        visit "/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        select tag_space.name, from: "tag-space-id"
        expect { select tag_space_wo_permissions.name, from: "tag-space-id" }.to raise_error Capybara::ElementNotFound
      end
    end

    describe "show" do
      it "can show virtual machine details" do
        vm
        visit "/vm"

        expect(page.title).to eq("Ubicloud - Virtual Machines")
        expect(page).to have_content vm.name

        click_link "Show", href: vm.path

        expect(page.title).to eq("Ubicloud - #{vm.name}")
        expect(page).to have_content vm.name
      end

      it "raises forbidden when does not have permissions" do
        visit vm_wo_permission.path

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when virtual machine not exists" do
        visit "/vm/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Page not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Page not found"
      end
    end

    describe "delete" do
      it "can delete virtual machine" do
        visit vm.path

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Deleting #{vm.name}"}.to_json)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "can not delete virtual machine when does not have permissions" do
        # Give permission to view, so we can see the detail page
        tag_space_wo_permissions.access_policies.first.update(body: {
          acls: [
            {subjects: user.hyper_tag_name, powers: ["Vm:view"], objects: tag_space_wo_permissions.hyper_tag_name}
          ]
        })

        visit vm_wo_permission.path

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
