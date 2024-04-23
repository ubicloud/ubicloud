# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

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
        choose option: "eu-north-h1"
        uncheck "Enable Public IPv4"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(Vm.count).to eq(1)
        expect(Vm.first.projects.first.id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).not_to be_nil
        expect(Vm.first.ip4_enabled).to be_falsey
      end

      it "can create new virtual machine with public ipv4" do
        project

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        name = "dummy-vm"
        fill_in "Name", with: name
        choose option: "eu-north-h1"
        check "Enable Public IPv4"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
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
        expect(page).to have_content "Create new subnet"
        name = "dummy-vm"
        fill_in "Name", with: name
        choose option: "eu-north-h1"
        select match: :prefer_exact, text: ps.name
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(Vm.count).to eq(1)
        expect(Vm.first.projects.first.id).to eq(project.id)
        expect(Vm.first.private_subnets.first.id).to eq(ps.id)
      end

      it "can not create virtual machine with invalid name" do
        project
        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")

        fill_in "Name", with: "invalid name"
        choose option: "eu-north-h1"
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
        choose option: "eu-north-h1"
        choose option: "ubuntu-jammy"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "name is already taken"
      end

      it "can not create virtual machine if project has no valid payment method" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

        visit "#{project.path}/vm/create"

        expect(page.title).to eq("Ubicloud - Create Virtual Machine")
        expect(page).to have_content "Project doesn't have valid billing information"

        fill_in "Name", with: "dummy-vm"
        choose option: "eu-north-h1"
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

        click_link "Show", href: "#{project.path}#{vm.path}"

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
        visit "#{project.path}/location/eu-north-h1/vm/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Resource not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Resource not found"
      end
    end

    describe "firewall_rules" do
      before do
        vm.update(display_state: "running")
      end

      it "does not list firewall rules if the VM is getting created" do
        vm.update(display_state: "creating")
        visit "#{project.path}#{vm.path}"

        expect(page.title).to eq("Ubicloud - #{vm.name}")
        expect(page).to have_no_content "Firewall Rules"
      end

      it "can show firewall rules" do
        vm
        # can visualize port_range nil as 0..65535
        vm.firewalls.map(&:firewall_rules).flatten.first.update(port_range: nil)

        visit "#{project.path}#{vm.path}"

        expect(page.title).to eq("Ubicloud - #{vm.name}")
        expect(page).to have_content "Firewall Rules"
        expect(page).to have_content "0.0.0.0/0"
        expect(page).to have_content "0..65535"
      end

      it "can delete firewall rule" do
        visit "#{project.path}#{vm.path}"

        # We send delete request manually instead of just clicking to button
        # because delete action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        btn = find "#fwr-delete-#{vm.firewalls.map(&:firewall_rules).flatten.first.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Firewall rule deleted"}.to_json)
        expect(SemSnap.new(vm.id).set?("update_firewall_rules")).to be true
      end

      it "can not delete firewall rule if not exist" do
        visit "#{project.path}#{vm.path}"

        # We send delete request manually instead of just clicking to button
        # because delete action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        btn = find "#fwr-delete-#{vm.firewalls.map(&:firewall_rules).flatten.first.ubid} .delete-btn"
        expect(FirewallRule).to receive(:[]).and_return(nil)
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(page.status_code).to eq(404)
      end

      it "can not delete firewall rule when does not have permissions" do
        # Give permission to view, so we can see the detail page
        project_wo_permissions.access_policies.first.update(body: {
          acls: [
            {subjects: user.hyper_tag_name, actions: ["Vm:view", "Vm:Firewall:view"], objects: project_wo_permissions.hyper_tag_name}
          ]
        })

        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}"

        expect { find "#fwr-delete-#{vm.firewalls.map(&:firewall_rules).flatten.first.ubid} .delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "does not show create firewall rule when does not have permissions" do
        # Give permission to view, so we can see the detail page
        project_wo_permissions.access_policies.first.update(body: {
          acls: [
            {subjects: user.hyper_tag_name, actions: ["Vm:view", "Vm:Firewall:view"], objects: project_wo_permissions.hyper_tag_name}
          ]
        })
        visit "#{project_wo_permissions.path}#{vm.path}"
        expect { find_by_id "fwr-create" }.to raise_error Capybara::ElementNotFound
      end

      it "can create firewall rule" do
        visit "#{project.path}#{vm.path}"

        fill_in "cidr", with: "1.1.1.2"
        click_button "Create"
        expect(page).to have_content "Firewall rule is created"
        expect(page).to have_content "1.1.1.2/32"
        expect(page).to have_content "0..65535"

        fill_in "cidr", with: "10.10.10.10"
        fill_in "port_range", with: "80..8080"
        click_button "Create"
        expect(page).to have_content "Firewall rule is created"
        expect(page).to have_content "10.10.10.10/32"
        expect(page).to have_content "80..8080"

        fill_in "cidr", with: "12.12.12.0/26"
        fill_in "port_range", with: "443"
        click_button "Create"
        expect(page).to have_content "Firewall rule is created"
        expect(page).to have_content "12.12.12.0/26"
        expect(page).to have_content "443"

        expect(SemSnap.new(vm.id).set?("update_firewall_rules")).to be true
      end
    end

    describe "delete" do
      it "can delete virtual machine" do
        visit "#{project.path}#{vm.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        btn = find "#vm-delete-#{vm.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Deleting #{vm.name}"}.to_json)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "can not delete virtual machine when does not have permissions" do
        # Give permission to view, so we can see the detail page
        project_wo_permissions.access_policies.first.update(body: {
          acls: [
            {subjects: user.hyper_tag_name, actions: ["Vm:view"], objects: project_wo_permissions.hyper_tag_name}
          ]
        })

        visit "#{project_wo_permissions.path}#{vm_wo_permission.path}"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
