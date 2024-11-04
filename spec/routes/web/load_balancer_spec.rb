# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "load balancer" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:lb) do
    ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
    lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
    lb.associate_with_project(project)
    lb
  end

  let(:lb_wo_permission) {
    ps = Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-2", location: "hetzner-fsn1").subject
    lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-2", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
    lb.associate_with_project(project_wo_permissions)
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

        click_link "New Load Balancer"
        expect(page.title).to eq("Ubicloud - Create Load Balancer")
      end

      it "can not list load balancers when does not have permissions" do
        lb
        lb_wo_permission
        visit "#{project.path}/load-balancer"

        expect(page.title).to eq("Ubicloud - Load Balancers")
        expect(page).to have_content lb.name
        expect(page).to have_no_content lb_wo_permission.name
      end
    end

    describe "create" do
      it "can create new load balancer" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
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
        expect(page).to have_content "'#{name}' is created"
        expect(LoadBalancer.count).to eq(1)
        expect(LoadBalancer.first.projects.first.id).to eq(project.id)
      end

      it "can not create load balancer with invalid name" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
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
        Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        visit "#{project_wo_permissions.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can not create load balancer with invalid private subnet" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
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
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000, algorithm: "hash_based").subject
        dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("key", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb.path}"
        select vm.name, from: "vm_id"
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content "VM is attached"
        expect(lb.vms.count).to eq(1)

        visit "#{project.path}#{lb.path}"
        expect(page).to have_content lb.name
        expect(page).to have_content vm.name
        expect(page).to have_content 80
        expect(page).to have_content 8000
        expect(page).to have_content "down"
        expect(page).to have_content "Hash Based"
      end

      it "can not attach vm when it is already attached to another load balancer" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        lb1 = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        lb2 = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-4", src_port: 80, dst_port: 8000).subject
        dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb1.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("key", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb2.path}"
        select vm.name, from: "vm_id"
        lb1.add_vm(vm)
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{lb2.name}")
        expect(page).to have_content "VM is already attached to a load balancer"
        expect(lb2.vms.count).to eq(0)
      end

      it "can not attach vm when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        vm = Prog::Vm::Nexus.assemble("key", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb.path}"
        select vm.name, from: "vm_id"
        vm.nics.first.destroy
        vm.destroy
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content "VM not found"
        expect(lb.vms.count).to eq(0)
      end

      it "can detach vm" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("key", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject
        expect(page).to have_no_content vm.name

        lb.add_vm(vm)

        visit "#{project.path}#{lb.path}"
        expect(page).to have_content vm.name
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content "VM is detached"
        expect(Strand.where(prog: "Vnet::LoadBalancerHealthProbes").all.count { |st| st.stack[0]["subject_id"] == lb.id && st.stack[0]["vm_id"] == vm.id }).to eq(0)
        expect(lb.update_load_balancer_set?).to be(true)
        expect(lb.load_balancers_vms_dataset.where(vm_id: vm.id).first.state).to eq("detaching")
      end

      it "can not detach vm when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject
        dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: project.id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
        lb.add_cert(cert)
        vm = Prog::Vm::Nexus.assemble("key", project.id, name: "dummy-vm-1", private_subnet_id: ps.id).subject

        visit "#{project.path}#{lb.path}"
        select "dummy-vm-1", from: "vm_id"
        click_button "Attach"
        visit "#{project.path}#{lb.path}"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(lb.reload.vms.count).to eq(1)
        vm.nics.first.destroy
        vm.destroy
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{lb.name}")
        expect(page).to have_content "VM not found"
        expect(lb.reload.vms.count).to eq(0)
      end
    end

    describe "delete" do
      it "can delete load balancer" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject

        visit "#{project.path}#{lb.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(lb.destroy_set?).to be true
      end

      it "can not delete load balancer when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessPolicy.create_with_id(
          project_id: project_wo_permissions.id,
          name: "only-view-load-balancer",
          body: {acls: [{subjects: user.hyper_tag_name, actions: ["LoadBalancer:view"], objects: project_wo_permissions.hyper_tag_name}]}
        )

        visit "#{project_wo_permissions.path}#{lb_wo_permission.path}"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "can not delete load balancer when it doesn't exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
        lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-3", src_port: 80, dst_port: 8000).subject

        visit "#{project.path}#{lb.path}"

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
