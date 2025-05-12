# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "private subnet" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:private_subnet) do
    ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).id
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

        click_link "Create Private Subnet"
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

      it "does not show new/create subnet without PrivateSubnet:create permissions" do
        visit "#{project.path}/private-subnet"
        expect(page).to have_content "Create Private Subnet"
        expect(page).to have_content "Get started by creating a new Private Subnet."

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])

        page.refresh
        expect(page).to have_content "No Private Subnets"
        expect(page).to have_content "You don't have permission to create Private Subnets."

        private_subnet
        page.refresh
        expect(page).to have_no_content "Create Private Subnet"
      end
    end

    describe "create" do
      it "can create new private subnet" do
        project
        visit "#{project.path}/private-subnet/create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")
        name = "dummy-ps"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_ID

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few seconds")
        expect(PrivateSubnet.count).to eq(1)
        expect(PrivateSubnet.first.project_id).to eq(project.id)
      end

      it "can not create private subnet with same name" do
        project
        visit "#{project.path}/private-subnet/create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")

        fill_in "Name", with: private_subnet.name
        choose option: Location::HETZNER_FSN1_ID

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")
        expect(page).to have_flash_error("project_id and location_id and name is already taken")
      end

      it "location not exist" do
        visit "#{project.path}/private-subnet/create"
        choose option: Location::HETZNER_FSN1_ID
        Location[Location::HETZNER_FSN1_ID].destroy

        click_button "Create"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content("ResourceNotFound")
      end

      it "can create new private subnet with same name after destroying it" do
        2.times do
          project
          visit "#{project.path}/private-subnet/create"

          expect(page.title).to eq("Ubicloud - Create Private Subnet")
          name = "dummy-ps"
          fill_in "Name", with: name
          choose option: Location::HETZNER_FSN1_ID

          click_button "Create"

          expect(page).to have_flash_notice("'#{name}' will be ready in a few seconds")
          expect(page.title).to eq("Ubicloud - #{name}")
          expect(PrivateSubnet.count).to eq(1)

          ps = PrivateSubnet.first
          expect(ps.project_id).to eq(project.id)

          visit "#{project.path}#{ps.path}"
          btn = find ".delete-btn"
          page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

          expect(SemSnap.new(ps.id).set?("destroy")).to be true
          ps.destroy
        end
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

      it "raises not found when private subnet not exists" do
        visit "#{project.path}/location/eu-central-h1/private-subnet/08s56d4kaj94xsmrnf5v5m3mav"

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
        fw = Firewall.create_with_id(name: "dummy-fw", description: "dummy-fw", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
        fw.associate_with_private_subnet(private_subnet)

        visit "#{project.path}#{private_subnet.path}"

        expect(page.title).to eq("Ubicloud - #{private_subnet.name}")
        expect(page).to have_content fw.name
        expect(page).to have_content fw.description
      end
    end

    describe "connected subnets" do
      it "can show connected subnets" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        private_subnet.connect_subnet(ps2)

        visit "#{project.path}#{private_subnet.path}"

        expect(page).to have_content ps2.name
        expect(page.all("a").map(&:text)).to include ps2.name

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"], object_id: private_subnet.id)
        page.refresh
        expect(page).to have_content ps2.name
        expect(page.all("a").map(&:text)).not_to include ps2.name
      end

      it "can disconnect connected subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        private_subnet.connect_subnet(ps2)

        visit "#{project.path}#{private_subnet.path}"

        expect(page).to have_content ps2.name

        btn = find "#cps-delete-#{ps2.ubid} .delete-btn"
        page.driver.post btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(private_subnet.reload.connected_subnets.count).to eq(0)
      end

      it "can connect to a subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        expect(private_subnet.connected_subnets.count).to eq(0)
        visit "#{project.path}#{private_subnet.path}"

        select ps2.name, from: "connected-subnet-id"
        click_button "Connect"

        expect(private_subnet.reload.connected_subnets.count).to eq(1)
      end

      it "cannot connect to a subnet when it does not exist" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}#{private_subnet.path}"
        ps2.strand.destroy
        ps2.destroy
        select "dummy-ps-2", from: "connected-subnet-id"
        click_button "Connect"

        expect(page).to have_flash_error("Subnet to be connected not found")
      end

      it "cannot disconnect a subnet when it does not exist" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        private_subnet.connect_subnet(ps2)
        visit "#{project.path}#{private_subnet.path}"
        small_id, large_id = (private_subnet.id < ps2.id) ? [private_subnet.id, ps2.id] : [ps2.id, private_subnet.id]
        ConnectedSubnet.where(subnet_id_1: small_id, subnet_id_2: large_id).destroy
        ps2.semaphores.map(&:destroy)
        ps2.strand.destroy
        ps2.destroy

        btn = find "#cps-delete-#{ps2.ubid} .delete-btn"
        page.driver.post btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.status_code).to eq(400)
        expect(page.body).to eq({error: {code: 400, type: "InvalidRequest", message: "Subnet to be disconnected not found"}}.to_json)
      end
    end

    describe "delete" do
      it "can delete private subnet" do
        visit "#{project.path}#{private_subnet.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(private_subnet.id).set?("destroy")).to be true
      end

      it "can not delete private subnet when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])

        visit "#{project_wo_permissions.path}#{ps_wo_permission.path}"
        expect(page.title).to eq "Ubicloud - dummy-ps-2"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "can not delete private subnet when there are active VMs" do
        private_subnet
        n_id = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32").id
        Prog::Vm::Nexus.assemble("key a", project.id, name: "dummy-vm", nic_id: n_id)

        visit "#{project.path}#{private_subnet.path}"
        btn = find ".delete-btn"
        Capybara.current_session.driver.header "Accept", "application/json"
        response = page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(response).to have_api_error(409, "Private subnet '#{private_subnet.name}' has VMs attached, first, delete them.")
      end
    end
  end
end
