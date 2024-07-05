# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "private subnet" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:private_subnet) do
    ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").id
    ps = PrivateSubnet[ps_id]
    ps.update(net6: "2a01:4f8:173:1ed3::/64")
    ps.update(net4: "172.17.226.128/26")
    ps.reload
  end

  let(:ps_wo_permission) {
    ps_id = Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-2").id
    PrivateSubnet[ps_id]
  }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/private-subnet"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/private-subnet/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no private subnets" do
        visit "#{project.path}/private-subnet"

        expect(page.title).to eq("Ubicloud - Private Subnets")
        expect(page).to have_content "No Private Subnets"

        click_link "New Private Subnet"
        expect(page.title).to eq("Ubicloud - Create Private Subnet")
      end

      it "can not list private subnets when does not have permissions" do
        private_subnet
        ps_wo_permission
        visit "#{project.path}/private-subnet"

        expect(page.title).to eq("Ubicloud - Private Subnets")
        expect(page).to have_content private_subnet.name
        expect(page).to have_no_content ps_wo_permission.name
      end
    end

    describe "create" do
      it "can create new private subnet" do
        project
        visit "#{project.path}/private-subnet/create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")
        name = "dummy-ps"
        fill_in "Name", with: name
        choose option: "eu-north-h1"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few seconds"
        expect(PrivateSubnet.count).to eq(1)
        expect(PrivateSubnet.first.projects.first.id).to eq(project.id)
      end

      it "can not create private subnet with invalid name" do
        project
        visit "#{project.path}/private-subnet/create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")

        fill_in "Name", with: "invalid name"
        choose option: "eu-north-h1"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create private subnet with same name" do
        project
        visit "#{project.path}/private-subnet/create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")

        fill_in "Name", with: private_subnet.name
        choose option: "eu-north-h1"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")
        expect(page).to have_content "name is already taken"
      end

      it "can not create vm in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/private-subnet/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end
    end

    describe "show" do
      it "can show private subnet details" do
        private_subnet
        visit "#{project.path}/private-subnet"

        expect(page.title).to eq("Ubicloud - Private Subnets")
        expect(page).to have_content private_subnet.name

        click_link private_subnet.name, href: "#{project.path}#{private_subnet.path}"

        expect(page.title).to eq("Ubicloud - #{private_subnet.name}")
        expect(page).to have_content private_subnet.name
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{ps_wo_permission.path}"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when private subnet not exists" do
        visit "#{project.path}/location/hetzner-hel1/private-subnet/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "show nics" do
      it "can show nic details" do
        private_subnet
        n_id = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32").id
        nic = Nic[n_id]
        visit "#{project.path}#{private_subnet.path}"

        expect(page.title).to eq("Ubicloud - #{private_subnet.name}")
        expect(page).to have_content nic.private_ipv4.network.to_s
        expect(page).to have_content nic.private_ipv6.nth(2).to_s
      end
    end

    describe "show firewalls" do
      it "can show attached firewalls" do
        private_subnet
        fw = Firewall.create_with_id(name: "dummy-fw", description: "dummy-fw")
        fw.associate_with_private_subnet(private_subnet)

        visit "#{project.path}#{private_subnet.path}"

        expect(page.title).to eq("Ubicloud - #{private_subnet.name}")
        expect(page).to have_content fw.name
        expect(page).to have_content fw.description
      end
    end

    describe "delete" do
      it "can delete private subnet" do
        visit "#{project.path}#{private_subnet.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Deleting #{private_subnet.name}"}.to_json)
        expect(SemSnap.new(private_subnet.id).set?("destroy")).to be true
      end

      it "can not delete private subnet when does not have permissions" do
        # Give permission to view, so we can see the detail page
        project_wo_permissions.access_policies.first.update(body: {
          acls: [
            {subjects: user.hyper_tag_name, actions: ["PrivateSubnet:view"], objects: project_wo_permissions.hyper_tag_name}
          ]
        })

        visit "#{project_wo_permissions.path}#{ps_wo_permission.path}"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "can not delete private subnet when there are active VMs" do
        private_subnet
        n_id = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32").id
        Prog::Vm::Nexus.assemble("key", project.id, name: "dummy-vm", nic_id: n_id)

        visit "#{project.path}#{private_subnet.path}"
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(page.body).to eq({message: "Private subnet has VMs attached, first, delete them."}.to_json)
      end
    end
  end
end
