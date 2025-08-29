# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "load balancer" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:lb) do
    ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
    lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 8080)
    lb
  end

  let(:lb_wo_permission) {
    ps = Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
    lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-2", health_check_endpoint: "/up", project_id: project_wo_permissions.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 8080)
    lb
  }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/load-balancer"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/load-balancer/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no load balancers" do
        visit "#{project.path}/load-balancer"

        expect(page.title).to eq("Ubicloud - Load Balancers")
        expect(page).to have_content "No Load Balancers"

        click_link "Create Load Balancer"
        expect(page.title).to eq("Ubicloud - Create Load Balancer")
      end

      it "can not list load balancers when does not have permissions" do
        lb
        lb_wo_permission
        visit "#{project.path}/load-balancer"

        expect(page.title).to eq("Ubicloud - Load Balancers")
        expect(page).to have_content lb.name
        expect(page).to have_no_content lb_wo_permission.name
        expect(page).to have_no_content "Waiting for hostname to be ready"
        expect(page).to have_content "Create Load Balancer"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["LoadBalancer:view"])
        page.refresh
        expect(page).to have_no_content "Create Load Balancer"
      end

      it "handles case where the user does not have permissions to create load balancers" do
        visit "#{project.path}/load-balancer"
        expect(page).to have_content "Get started by creating a new Load Balancer."
        expect(page).to have_no_content "You don't have permission to create Load Balancers."

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["LoadBalancer:view"])
        page.refresh
        expect(page).to have_content "You don't have permission to create Load Balancers."
        expect(page).to have_no_content "Get started by creating a new Load Balancer."
      end
    end

    describe "create" do
      it "can create new load balancer" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")
        name = "dummy-lb-1"
        fill_in "Name", with: name
        fill_in "Load Balancer Port", with: 80
        fill_in "Application Port", with: 8000
        select "Round Robin", from: "algorithm"
        fill_in "HTTP Health Check Endpoint", with: "/up"
        select ps.name, from: "private_subnet_id"
        select "HTTP", from: "health_check_protocol"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' is created")
        expect(LoadBalancer.count).to eq(1)
        expect(LoadBalancer.first.project_id).to eq(project.id)
      end

      it "can not create load balancer with invalid name" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")

        fill_in "Name", with: "invalid name"
        fill_in "Load Balancer Port", with: 80
        fill_in "Application Port", with: 8000
        select "Round Robin", from: "algorithm"
        fill_in "HTTP Health Check Endpoint", with: "/up"
        select ps.name, from: "private_subnet_id"
        select "HTTP", from: "health_check_protocol"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create load balancer in a project when does not have permissions" do
        Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project_wo_permissions.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can not create load balancer with invalid private subnet" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")

        fill_in "Name", with: "dummy-lb-1"
        fill_in "Load Balancer Port", with: 80
        fill_in "Application Port", with: 8000
        select "Round Robin", from: "algorithm"
        fill_in "HTTP Health Check Endpoint", with: "/up"
        select ps.name, from: "private_subnet_id"
        select "HTTP", from: "health_check_protocol"

        ps.destroy

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")
        expect(page).to have_content "Private subnet not found"
      end
    end

    describe "show" do
      it "can show load balancer details" do
        lb
        visit "#{project.path}/load-balancer"

        expect(page.title).to eq("Ubicloud - Load Balancers")
        expect(page).to have_content lb.name
        expect(page).to have_content lb.hostname

        click_link lb.name, href: "#{project.path}#{lb.path}"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content lb.name
        expect(page).to have_content "Round Robin"
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}/location/eu-central-h1/load-balancer/#{lb_wo_permission.name}"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when load balancer not exists" do
        visit "#{project.path}/location/eu-central-h1/load-balancer/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "load-balancers" do
      it "can show" do
        visit "#{project.path}#{lb.path}"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content lb.name
        expect(page).to have_content lb.private_subnet.name
        expect(page).to have_content "Round Robin"
        expect(page).to have_content "/up"
      end

      it "can attach vm" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000, algorithm: "hash_based").subject
        dz = DnsZone.create(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb.path}/vms"
        select vm.name, from: "vm_id"
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_flash_notice("VM is attached to the load balancer")
        expect(lb.vms.count).to eq(1)

        expect(Config).to receive(:load_balancer_service_hostname).and_return("lb.ubicloud.com").twice
        visit "#{project.path}#{lb.path}"
        expect(page.all("dt,dd").map(&:text)).to eq [
          "ID", lb.ubid,
          "Name", "dummy-lb-3",
          "Connection String", "dummy-lb-3.#{ps.ubid[-5...]}.lb.ubicloud.com",
          "Private Subnet", "dummy-ps-1",
          "Algorithm", "Hash Based",
          "Stack", "dual",
          "Load Balancer Port", "80",
          "Application Port", "8000",
          "HTTP Health Check Endpoint", "/up"
        ]
        visit "#{project.path}#{lb.path}/vms"
        expect(page.all("#lb-vms td").map(&:text)).to eq [
          "dummy-vm-1", "down", "Detach",
          "Select a VM", "", "Attach"
        ]

        within("#load-balancer-submenu") { click_link "Overview" }
        click_link "dummy-ps-1"
        expect(page.title).to eq("Ubicloud - #{ps.name}")
      end

      it "can not attach vm when it is already attached to another load balancer" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        lb1 = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        lb2 = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-4", src_port: 80, dst_port: 8000).subject
        dz = DnsZone.create(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb1.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb2.path}"
        within("#load-balancer-submenu") { click_link "Virtual Machines" }
        select vm.name, from: "vm_id"
        lb1.add_vm(vm)
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{lb2.name}")
        expect(page).to have_content "VM is already attached to a load balancer"
        expect(lb2.vms.count).to eq(0)
      end

      it "can not attach vm when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb.path}/vms"
        select vm.name, from: "vm_id"
        vm.nics.first.destroy
        vm.destroy
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content "No matching VM found in eu-central-h1"
        expect(lb.vms.count).to eq(0)
      end

      it "can detach vm" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        dz = DnsZone.create(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject
        expect(page).to have_no_content vm.name

        lb.add_vm(vm)

        visit "#{project.path}#{lb.path}/vms"
        expect(page).to have_content vm.name
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_flash_notice("VM is detached from the load balancer")
        expect(Strand.where(prog: "Vnet::LoadBalancerHealthProbes").all.count { |st| st.stack[0]["subject_id"] == lb.id && st.stack[0]["vm_id"] == vm.id }).to eq(0)
        expect(lb.update_load_balancer_set?).to be(true)
        expect(lb.vm_ports_dataset.where(load_balancer_vm_id: LoadBalancerVm.where(vm_id: vm.id).select(:id)).first&.state).to eq("detaching")
      end

      it "can not detach vm when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        dz = DnsZone.create(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb.path}/vms"
        select "dummy-vm-1", from: "vm_id"
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(lb.reload.vms.count).to eq(1)
        vm.nics.first.destroy
        vm.destroy
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content "No matching VM found in eu-central-h1"
        expect(lb.reload.vms.count).to eq(0)
      end

      it "can not attach vms without permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["LoadBalancer:view"])

        visit "#{project_wo_permissions.path}#{lb_wo_permission.path}/vms"
        expect(page.title).to eq "Ubicloud - dummy-lb-2"

        expect(page.body).not_to include "attach-vm"
      end
    end

    describe "rename" do
      it "can rename load balancer" do
        old_name = lb.name
        visit "#{project.path}#{lb.path}/settings"
        fill_in "name", with: "new-name%"
        click_button "Rename"
        expect(page).to have_flash_error("Validation failed for following fields: name")
        expect(page).to have_content("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
        expect(lb.reload.name).to eq old_name

        fill_in "name", with: "new-name"
        click_button "Rename"
        expect(page).to have_flash_notice("Name updated")
        expect(lb.reload.name).to eq "new-name"
        expect(page).to have_content("new-name")
      end

      it "does not show rename option without permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:view"])
        visit "#{project_wo_permissions.path}#{lb_wo_permission.path}/settings"
        expect(page).to have_no_content("Rename")
      end
    end

    describe "delete" do
      it "can delete load balancer" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject

        visit "#{project.path}#{lb.path}"
        within("#load-balancer-submenu") { click_link "Settings" }

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(lb.destroy_set?).to be true
      end

      it "can not delete load balancer when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["LoadBalancer:view"])

        visit "#{project_wo_permissions.path}#{lb_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - dummy-lb-2"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "can not delete load balancer when it doesn't exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject

        visit "#{project.path}#{lb.path}/settings"

        lb.update(name: "new-name")
        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.status_code).to eq(204)
      end
    end
  end
end
