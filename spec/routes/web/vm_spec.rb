# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-1").subject
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  let(:vm_wo_permission) { Prog::Vm::Nexus.assemble("dummy-public-key", project_wo_permissions.id, name: "dummy-vm-2").subject }

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
        visit "#{project.path}/vm"

        expect(page.title).to eq("Ubicloud - Virtual Machines")
        expect(page).to have_content "No virtual machines"

        click_link "New Virtual Machine"
        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
      end

      it "can not list virtual machines when does not have permissions" do
        vm
        vm_wo_permission
        visit "#{project.path}/vm"

        expect(page.title).to eq("Ubicloud - Virtual Machines")
        expect(page).to have_content vm.name
        expect(page).to have_no_content vm_wo_permission.name
      end
    end

    describe "create" do
      it "can create new virtual machine" do
        project

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        choose option: "eu-central-h1"
        uncheck "enable_ip4"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.projects.first.id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to be_nil
        expect(Vm.first.ip4_enabled).to be_falsey
      end

      it "shows expected information on index page" do
        project

        visit "#{project.path}/vm"
        expect(page).to have_content "Get started by creating a new virtual machine."
        click_link "New Virtual Machine"
        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        click_button "Create"
        vm_host = VmHost.new_with_id(location: "test")
        Sshable.create { |s| s.id = vm_host.id }
        vm_host.save_changes
        address = Address.create(
          cidr: "1.2.3.0/24",
          routed_to_host_id: vm_host.id
        )
        vm.assigned_vm_address = AssignedVmAddress.new_with_id(
          ip: "1.2.3.4",
          address_id: address.id
        )
        spdk_installation = SpdkInstallation.create(
          version: "1",
          allocation_weight: 1
        ) { |obj| obj.id = SpdkInstallation.generate_uuid }
        storage_device = StorageDevice.create(
          name: "t",
          total_storage_gib: 147,
          available_storage_gib: 24
        )
        storage_volume = VmStorageVolume.new(
          boot: true,
          size_gib: 123,
          disk_index: 1,
          spdk_installation_id: spdk_installation.id,
          storage_device_id: storage_device.id
        )
        vm.add_vm_storage_volume(storage_volume)

        visit "#{project.path}/vm"
        page.refresh
        expect(page).to have_content "Create Virtual Machine"
        expect(page).to have_content "123 GB"
        expect(page).to have_content "1.2.3.4"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Vm:view"])
        storage_volume.update(size_gib: 0)
        vm.assigned_vm_address.destroy
        vm.update(ephemeral_net6: nil)
        page.refresh
        expect(page).to have_no_content "Create Virtual Machine"
        expect(page).to have_content "Not assigned yet"

        Nic.dataset.destroy
        vm.destroy
        page.refresh
        expect(page).to have_no_content "New Virtual Machine"
        expect(page).to have_content "You don't have permission to create virtual machines."
      end

      it "can create new virtual machine with public ipv4" do
        project

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        choose option: "eu-central-h1"
        check "enable_ip4"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.projects.first.id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to be_nil
        expect(Vm.first.ip4_enabled).to be_truthy
      end

      it "can create new virtual machine with chosen private subnet" do
        project
        ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1").id
        ps = PrivateSubnet[ps_id]
        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content ps.name
        name = "dummy-vm"
        fill_in "Name", with: name
        choose option: "eu-central-h1"
        select match: :prefer_exact, text: ps.name
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.projects.first.id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).to eq(ps.id)
      end

      it "can create new virtual machine in default location subnet" do
        project
        ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1").id
        ps = PrivateSubnet[ps_id]
        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "Default"
        name = "dummy-vm"
        fill_in "Name", with: name
        choose option: "eu-central-h1"
        select match: :prefer_exact, text: "Default"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.projects.first.id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to eq(ps.id)
        expect(Vm.first.private_subnets.first.name).to eq("default-#{LocationNameConverter.to_display_name(ps.location)}")

        # can create a second vm in the same location and it will use the same subnet
        visit "#{project.path}/vm/create"
        fill_in "Name", with: "dummy-vm-2"
        choose option: "eu-central-h1"
        select match: :prefer_exact, text: "Default"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - dummy-vm-2")
        expect(Vm.count).to eq(2)
        expect(Vm.find(name: "dummy-vm-2").private_subnets.first.id).to eq(Vm.find(name: "dummy-vm").private_subnets.first.id)
      end

      it "can not create virtual machine with invalid name" do
        project
        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        fill_in "Name", with: "invalid name"
        choose option: "eu-central-h1"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create virtual machine with same name" do
        project
        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        fill_in "Name", with: vm.name
        choose option: "eu-central-h1"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_flash_error("project_id and name is already taken")
      end

      it "can not create virtual machine if project has no valid payment method" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "Project doesn't have valid billing information"

        fill_in "Name", with: "dummy-vm"
        choose option: "eu-central-h1"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "Project doesn't have valid billing information"
      end

      it "can not select invisible location" do
        project
        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        expect { choose option: "github-runners" }.to raise_error Capybara::ElementNotFound
      end

      it "can not create vm in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end
    end

    describe "show" do
      it "can show virtual machine details" do
        vm
        visit "#{project.path}/vm"

        expect(page.title).to eq("Ubicloud - Virtual Machines")
        expect(page).to have_content vm.name

        click_link vm.name, href: "#{project.path}#{vm.path}"

        expect(page.title).to eq("Ubicloud - #{vm.name}")
        expect(page).to have_content vm.name
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when virtual machine not exists" do
        visit "#{project.path}/location/eu-central-h1/vm/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "delete" do
      it "can delete virtual machine" do
        visit "#{project.path}#{vm.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        btn = find "#vm-delete-#{vm.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "can not delete virtual machine when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Vm:view"])

        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}"
        expect(page.title).to eq "Ubicloud - dummy-vm-2"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end

    describe "restart" do
      it "can restart vm" do
        visit "#{project.path}#{vm.path}"
        expect(page).to have_content "Restart"
        click_button "Restart"

        expect(page.status_code).to eq(200)
        expect(vm.restart_set?).to be true
      end
    end
  end
end
