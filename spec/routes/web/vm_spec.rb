# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-1").subject
    vm.update(ephemeral_net6: NetAddr::IPv6Net.parse("2a01:4f8:173:1ed3:aa7c::/79"))
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  let(:vm_wo_permission) { Prog::Vm::Nexus.assemble("dummy-public key", project_wo_permissions.id, name: "dummy-vm-2").subject }

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

        click_link "Create Virtual Machine"
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
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        uncheck "enable_ip4"
        choose option: "ubuntu-jammy"
        choose option: "standard-4"

        click_button "Create"
        expect(page).to have_flash_error("Validation failed for following fields: storage_size")

        choose option: "standard-2"
        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        vm = Vm.first
        expect(vm.boot_image).to eq("ubuntu-jammy")
        expect(vm.project_id).to eq(project.id)
        expect(vm.private_subnets.first.id).not_to be_nil
        expect(vm.ip4_enabled).to be_falsey

        visit project.path
        expect(page).to have_content("2/32 (6%)")
        vm.update(vcpus: 25)
        page.refresh
        expect(page).to have_content("25/32 (78%)")
        vm.update(vcpus: 31)
        page.refresh
        expect(page).to have_content("31/32 (96%)")
      end

      it "shows 404 page if attempting to create a VM with an invalid location" do
        visit "#{project.path}/vm/create"
        fill_in "Name", with: "dummy-vm"
        choose "Germany"

        Location.where(display_name: "eu-central-h1").destroy
        click_button "Create"
        expect(page.status_code).to eq 404
      end

      it "shows 404 page if attempting to create a VM with an invalid location format" do
        visit "#{project.path}/vm/create"
        fill_in "Name", with: "dummy-vm"
        choose "Germany"

        # Monkey with location id to use non-uuid format
        page.driver.browser.dom.css("[value=\"#{Location::HETZNER_FSN1_UBID}\"]").attr("value", "foo")

        click_button "Create"
        expect(page.status_code).to eq 404
      end

      it "shows vm create page with burstable and location_latitude_fra" do
        project.set_ff_visible_locations ["latitude-fra"]
        visit "#{project.path}/vm/create"
        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
      end

      it "shows expected information on index page" do
        project

        visit "#{project.path}/vm"
        expect(page).to have_content "Get started by creating a new virtual machine."
        click_link "Create Virtual Machine"
        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        click_button "Create"
        address = Address.create(
          cidr: "1.2.3.0/24",
          routed_to_host_id: create_vm_host.id
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

        click_link vm.name
        expect(page).to have_content "123 GB"
        expect(page.body).to include "auto-refresh hidden"

        vm.this.update(display_state: "running")
        page.refresh
        expect(page.body).not_to include "auto-refresh hidden"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Vm:view"])
        storage_volume.update(size_gib: 0)
        vm.assigned_vm_address.destroy
        vm.update(ephemeral_net6: nil)
        visit "#{project.path}/vm"
        expect(page).to have_no_content "Create Virtual Machine"
        expect(page).to have_content "Not assigned yet"

        Nic.dataset.destroy
        vm.destroy
        page.refresh
        expect(page).to have_no_content "New Virtual Machine"
        expect(page).to have_content "You don't have permission to create virtual machines."
      end

      it "can create new virtual machine using registered SSH public key" do
        project.add_ssh_public_key(name: "my-spk", public_key: "a a")

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content("Registered SSH Public Key")
        name = "dummy-vm"
        fill_in "Name", with: name
        select "my-spk"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to be_nil
        expect(Vm.first.public_key).to eq "a a"
      end

      it "can create new virtual machine using init script" do
        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        fill_in "Init Script", with: "foo bar"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to be_nil
        expect(Vm.first.init_script.script).to eq "foo bar"
      end

      it "can create new virtual machine with public ipv4" do
        project

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_no_content("Registered SSH Public Key")
        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        check "enable_ip4"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to be_nil
        expect(Vm.first.ip4_enabled).to be_truthy
      end

      it "can create new virtual machine in a new private subnet" do
        project

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        find("option[value=new-#{Location::HETZNER_FSN1_UBID}]").select_option
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"
        click_button "Create"
        expect(page).to have_flash_error("empty string provided for parameter new_private_subnet_name")

        fill_in "Private Subnet Name", with: "bad ps name"
        click_button "Create"
        expect(page).to have_flash_error("Validation failed for following fields: new_private_subnet_name")
        expect(page).to have_content("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
        fill_in "Private Subnet Name", with: "test-ps-name"
        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)
        expect(Vm.first.private_subnets.first.name).to eq "test-ps-name"
      end

      it "can create a virtual machine with gpu" do
        project
        project.set_ff_gpu_vm(true)
        vmh = Prog::Vm::HostNexus.assemble("::1", location_id: Location::HETZNER_FSN1_ID).subject
        pci = PciDevice.new_with_id(
          vm_host_id: vmh.id,
          slot: "01:00.0",
          device_class: "0300",
          vendor: "10de",
          device: "20b5",
          numa_node: nil,
          iommu_group: 0
        )
        vmh.save_changes
        pci.save_changes

        # Older links allow selecting both GPU and non-GPU options
        visit "#{project.path}/vm/create"

        click_button "Create"
        expect(page).to have_content "GPU"
        expect(page).to have_content "Finland"
        expect(page).to have_content "Burstable"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"
        choose option: "1:20b5"
        expect(page).to have_content "GPU"
        expect(page).to have_content "Finland"
        expect(page).to have_content "Burstable"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)

        pci.update(vm_id: Vm.first.id)
        page.refresh
        expect(page).to have_content "1x NVIDIA A100 80GB PCIe"
      end

      it "handles case where no gpus are available on create gpu virtual machine page by redirecting" do
        project
        project.set_ff_gpu_vm(true)
        visit "#{project.path}/vm"
        click_link "Create GPU Virtual Machine"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_flash_error("Unfortunately, no virtual machines with GPUs are currently available.")
      end

      it "can create a virtual machine with gpu on create gpu virtual machine page" do
        project
        project.set_ff_gpu_vm(true)

        vmh = Prog::Vm::HostNexus.assemble("::1", location_id: Location::HETZNER_FSN1_ID).subject
        pci = PciDevice.new_with_id(
          vm_host_id: vmh.id,
          slot: "01:00.0",
          device_class: "0300",
          vendor: "10de",
          device: "20b5",
          numa_node: nil,
          iommu_group: 0
        )
        vmh.save_changes
        pci.save_changes

        visit "#{project.path}/vm"
        click_link "Create GPU Virtual Machine"

        expect(page.title).to eq("Ubicloud - Create GPU Virtual Machine")
        expect(page).to have_content "GPU"
        expect(page).to have_no_content "Finland"
        expect(page).to have_no_content "Burstable"
        click_button "Create"
        expect(page).to have_flash_error("empty string provided for parameter public_key")

        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"
        choose option: "1:20b5"
        expect(page).to have_content "GPU"
        expect(page).to have_no_content "Finland"
        expect(page).to have_no_content "Burstable"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)

        pci.update(vm_id: Vm.first.id)
        page.refresh
        expect(page).to have_content "1x NVIDIA A100 80GB PCIe"

        visit "#{project.path}/vm"
        click_link "Create Virtual Machine"
        expect(page).to have_no_content "GPU"
      end

      it "cannot create a virtual machine with gpu if choosing create virtual machine page" do
        project
        project.set_ff_gpu_vm(true)
        vmh = Prog::Vm::HostNexus.assemble("::1", location_id: Location::HETZNER_FSN1_ID).subject
        pci = PciDevice.new_with_id(
          vm_host_id: vmh.id,
          slot: "01:00.0",
          device_class: "0300",
          vendor: "10de",
          device: "20b5",
          numa_node: nil,
          iommu_group: 0
        )
        vmh.save_changes
        pci.save_changes

        visit "#{project.path}/vm"
        click_link "Create Virtual Machine"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_no_content "GPU"
        expect(page).to have_content "Finland"
        expect(page).to have_content "Burstable"

        click_button "Create"
        expect(page).to have_flash_error("empty string provided for parameter public_key")

        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        expect(page).to have_no_content "GPU"
        expect(page).to have_content "Finland"
        expect(page).to have_content "Burstable"
      end

      it "shows invisible locations if feature flag is enabled" do
        project
        project.set_ff_gpu_vm(true)
        project.set_ff_visible_locations(["latitude-ai"])
        vmh = Prog::Vm::HostNexus.assemble("::1", location_id: Location[name: "latitude-ai"].id).subject
        pci = PciDevice.new_with_id(
          vm_host_id: vmh.id,
          slot: "01:00.0",
          device_class: "0300",
          vendor: "10de",
          device: "20b5",
          numa_node: nil,
          iommu_group: 0
        )
        vmh.save_changes
        pci.save_changes

        visit "#{project.path}/vm"
        click_link "Create GPU Virtual Machine"

        expect(page.title).to eq("Ubicloud - Create GPU Virtual Machine")
        expect(page).to have_content "GPU"
        expect(page).to have_content "latitude-ai"
      end

      it "cannot create a virtual machine with gpu if feature switch is disabled" do
        project
        vmh = Prog::Vm::HostNexus.assemble("::1", location_id: Location::HETZNER_FSN1_ID).subject
        pci = PciDevice.new_with_id(
          vm_host_id: vmh.id,
          slot: "01:00.0",
          device_class: "0300",
          vendor: "10de",
          device: "20b5",
          numa_node: nil,
          iommu_group: 0
        )
        vmh.save_changes
        pci.save_changes

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        expect(page).to have_no_content "GPU"
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
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        select match: :prefer_exact, text: ps.name
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)
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
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        select match: :prefer_exact, text: "Default"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(Vm.count).to eq(1)
        expect(Vm.first.project_id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to eq(ps.id)
        expect(Vm.first.private_subnets.first.name).to eq("default-#{ps.location.display_name}")

        # can create a second vm in the same location and it will use the same subnet
        visit "#{project.path}/vm/create"
        fill_in "Name", with: "dummy-vm-2"
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
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
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
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
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_flash_error("project_id and location_id and name is already taken")
      end

      it "can not create virtual machine if project has no valid payment method" do
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project).twice
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "Project doesn't have valid billing information"

        fill_in "Name", with: "dummy-vm"
        choose option: Location::HETZNER_FSN1_UBID
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

        expect { choose option: "6b9ef786-b842-8420-8c65-c25e3d4bdf3d" }.to raise_error Capybara::ElementNotFound
      end

      it "cannot create vm in invisible location" do
        project
        visit "#{project.path}/vm/create"
        fill_in "Name", with: "dummy-vm"
        choose option: Location::HETZNER_FSN1_UBID

        Location.where(id: Location::HETZNER_FSN1_ID).update(visible: false)
        click_button "Create"
        expect(page.status_code).to eq(404)
      end

      it "cannot create vm in private location tied to other project" do
        project
        visit "#{project.path}/vm/create"
        fill_in "Name", with: "dummy-vm"
        choose option: Location::HETZNER_FSN1_UBID

        Location.where(id: Location::HETZNER_FSN1_ID).update(visible: false, project_id: project_wo_permissions.id)
        click_button "Create"
        expect(page.status_code).to eq(404)
      end

      it "can create vm in private location tied to current project" do
        project
        visit "#{project.path}/vm/create"
        name = "dummy-vm"
        fill_in "Name", with: name
        fill_in "SSH Public Key", with: "a a"
        choose option: Location::HETZNER_FSN1_UBID

        Location.where(id: Location::HETZNER_FSN1_ID).update(visible: false, project_id: project.id)
        click_button "Create"
        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
      end

      it "can not create vm in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "cannot create vm when location not exist" do
        visit "#{project.path}/vm/create"
        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        fill_in "Name", with: "cannotcreate"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        Location[Location::HETZNER_FSN1_ID].destroy
        click_button "Create"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content("ResourceNotFound")
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

      it "cannot list when location not exist" do
        visit "#{project.path}/location/not-exist-location/vm"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "networking" do
      it "shows firewall rules" do
        visit "#{project.path}#{vm.path}"
        within("#vm-submenu") { click_link "Networking" }
        expect(page.all("#vm-firewall-rules td").map(&:text)).to eq [
          "default-eu-central-h1-default", "0.0.0.0/0", "0..65535",
          "default-eu-central-h1-default", "::/0", "0..65535"
        ]
        page.all("#vm-firewall-rules td a").first.click
        expect(page.title).to eq "Ubicloud - default-eu-central-h1-default"
      end

      it "does not link to firewalls that are not viewable" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Vm:view"])
        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}/networking"
        expect(page.all("#vm-firewall-rules td").map(&:text)).to eq [
          "default-eu-central-h1-default", "0.0.0.0/0", "0..65535",
          "default-eu-central-h1-default", "::/0", "0..65535"
        ]
        expect(page.all("#vm-firewall-rules td a").to_a).to eq []
      end
    end

    describe "rename" do
      it "can rename virtual machine" do
        old_name = vm.name
        visit "#{project.path}#{vm.path}/settings"
        fill_in "name", with: "new-name%"
        click_button "Rename"
        expect(page).to have_flash_error("Validation failed for following fields: name")
        expect(page).to have_content("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
        expect(vm.reload.name).to eq old_name

        fill_in "name", with: "new-name"
        click_button "Rename"
        expect(page).to have_flash_notice("Name updated")
        expect(vm.reload.name).to eq "new-name"
        expect(page).to have_content("new-name")
      end

      it "does not show rename option without permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:view"])
        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}/settings"
        expect(page).to have_no_content("Rename")
      end
    end

    describe "delete" do
      it "can delete virtual machine" do
        visit "#{project.path}#{vm.path}"
        within("#vm-submenu") { click_link "Settings" }

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        btn = find "#vm-delete-#{vm.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "can not delete virtual machine when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Vm:view"])

        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - dummy-vm-2"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end

    describe "restart" do
      it "can restart vm" do
        visit "#{project.path}#{vm.path}"
        within("#vm-submenu") { click_link "Settings" }
        expect(page).to have_content "Restart"
        click_button "Restart"

        expect(page.status_code).to eq(200)
        expect(vm.restart_set?).to be true
      end

      it "can not restart virtual machine without edit permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Vm:view"])

        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - dummy-vm-2"

        expect(page).to have_no_content "Restart"
      end
    end
  end
end
