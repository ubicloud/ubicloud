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
        choose option: Location::HETZNER_FSN1_UBID

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
        choose option: Location::HETZNER_FSN1_UBID

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Private Subnet")
        expect(page).to have_flash_error("project_id and location_id and name is already taken")
      end

      it "location not exist" do
        visit "#{project.path}/private-subnet/create"
        choose option: Location::HETZNER_FSN1_UBID
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
          name = "a123456789" * 6
          fill_in "Name", with: name
          choose option: Location::HETZNER_FSN1_UBID

          click_button "Create"

          expect(page).to have_flash_notice("'#{name}' will be ready in a few seconds")
          expect(page.title).to eq("Ubicloud - #{name}")
          expect(PrivateSubnet.count).to eq(1)

          ps = PrivateSubnet.first
          expect(ps.project_id).to eq(project.id)

          visit "#{project.path}#{ps.path}/settings"
          click_button "Delete"
          expect(page).to have_flash_notice("Private subnet scheduled for deletion.")

          expect(SemSnap.new(ps.id).set?("destroy")).to be true
          ps.destroy
        end

        expect(Firewall.where(name: "a123456789a123456789a123456789a123456789a123456789a1234-default")).not_to be_empty
        expect(Firewall.count).to eq 2
        expect(Firewall.get { sum(Sequel.char_length(:name)) }).to eq 126
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
        within("#private-subnet-submenu") { click_link "Virtual Machines" }

        expect(page.title).to eq("Ubicloud - #{private_subnet.name}")
        expect(page).to have_content nic.private_ipv4.network.to_s
        expect(page).to have_content nic.private_ipv6.nth(2).to_s

        Prog::Vm::Nexus.assemble("key a", project.id, name: "dummy-vm", nic_id: n_id)
        page.refresh
        expect(page).to have_content "dummy-vm"
        expect(page.all("#private-subnet-nics a").length).to eq 1
        click_link "dummy-vm"
        expect(page.title).to eq("Ubicloud - dummy-vm")

        AccessControlEntry.where(project_id: project.id, action_id: nil).update(action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        visit "#{project.path}#{private_subnet.path}/vms"
        expect(page).to have_content "dummy-vm"
        expect(page.all("#private-subnet-nics a").to_a).to eq []
      end

      it "does not show nics for vms in other projects" do
        Prog::Vm::Nexus.assemble("some_ssh key", Project.create(name: "other").id, private_subnet_id: private_subnet.id, allow_private_subnet_in_other_project: true, name: "other-vm")
        visit "#{project.path}#{private_subnet.path}/vms"
        expect(page).to have_no_content "other-vm"
        expect(page.all("#private-subnet-nics a").to_a).to eq []
      end
    end

    describe "show firewalls" do
      it "can show attached firewalls" do
        private_subnet
        fw = Firewall.create(name: "dummy-fw", description: "dummy-fw", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
        fw.associate_with_private_subnet(private_subnet)

        visit "#{project.path}#{private_subnet.path}/networking"

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
        within("#private-subnet-submenu") { click_link "Networking" }

        expect(page).to have_content ps2.name
        expect(page.all("a").map(&:text)).to include ps2.name

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"], object_id: private_subnet.id)
        page.refresh
        expect(page).to have_content ps2.name
        expect(page.all("a").map(&:text)).not_to include ps2.name
      end

      it "can disconnect connected subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        private_subnet.connect_subnet(ps2)

        visit "#{project.path}#{private_subnet.path}/networking"

        expect(page).to have_content ps2.name

        click_button "Disconnect"
        expect(private_subnet.reload.connected_subnets.count).to eq(0)
      end

      it "can connect to a subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        expect(private_subnet.connected_subnets.count).to eq(0)
        visit "#{project.path}#{private_subnet.path}/networking"

        select ps2.name, from: "connected-subnet-id"
        click_button "Connect"

        expect(private_subnet.reload.connected_subnets.count).to eq(1)
      end

      it "cannot connect to a subnet in a different location" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}#{private_subnet.path}/networking"
        ps2.strand.destroy
        ps2.update(location_id: Location::HETZNER_HEL1_ID)
        select "dummy-ps-2", from: "connected-subnet-id"
        click_button "Connect"

        expect(page).to have_flash_error("Subnet to be connected not found")
        expect(page).to have_no_content("dummy-ps-2")
      end

      it "cannot connect to a subnet when it does not exist" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}#{private_subnet.path}/networking"
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
        visit "#{project.path}#{private_subnet.path}/networking"
        small_id, large_id = (private_subnet.id < ps2.id) ? [private_subnet.id, ps2.id] : [ps2.id, private_subnet.id]
        ConnectedSubnet.where(subnet_id_1: small_id, subnet_id_2: large_id).destroy
        ps2.semaphores.map(&:destroy)
        ps2.strand.destroy
        ps2.destroy

        click_button "Disconnect"
        expect(page.status_code).to eq(400)
        expect(page).to have_flash_error("Subnet to be disconnected not found")
        expect(page.title).to eq("Ubicloud - dummy-ps-1")
      end

      it "cannot connect to a subnet without access to connected subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        expect(private_subnet.connected_subnets.count).to eq(0)
        visit "#{project.path}#{private_subnet.path}/networking"

        select ps2.name, from: "connected-subnet-id"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:connect"], object_id: private_subnet.id)
        select "dummy-ps-2"
        click_button "Connect"
        expect(private_subnet.reload.connected_subnets.count).to eq(0)
        expect(page.title).to eq "Ubicloud - dummy-ps-1"
        expect(page).to have_flash_error "Subnet to be connected not found"
        expect { select "dummy-ps-2" }.to raise_error(Capybara::ElementNotFound)
      end

      it "cannot disconnect connected subnet without access to connected subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        private_subnet.connect_subnet(ps2)

        visit "#{project.path}#{private_subnet.path}/networking"

        expect(page).to have_content ps2.name

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:disconnect"], object_id: private_subnet.id)

        click_button "Disconnect"
        expect(private_subnet.reload.connected_subnets.count).to eq(1)
        expect(page.title).to eq "Ubicloud - dummy-ps-1"
        expect(page).to have_flash_error "Subnet to be disconnected not found"
        expect(page).to have_no_content "Disconnect"
      end

      it "cannot connect to a subnet without access to current subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        expect(private_subnet.connected_subnets.count).to eq(0)
        visit "#{project.path}#{private_subnet.path}/networking"

        select ps2.name, from: "connected-subnet-id"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:connect"], object_id: ps2.id)
        click_button "Connect"
        expect(private_subnet.reload.connected_subnets.count).to eq(0)
        expect(page.title).to eq "Ubicloud - Forbidden"

        visit "#{project.path}#{private_subnet.path}/networking"
        expect { click_button "Connect" }.to raise_error(Capybara::ElementNotFound)
      end

      it "cannot disconnect connected subnet without access to current subnet" do
        private_subnet
        ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
        private_subnet.connect_subnet(ps2)

        visit "#{project.path}#{private_subnet.path}/networking"

        expect(page).to have_content ps2.name

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:disconnect"], object_id: ps2.id)

        click_button "Disconnect"
        expect(private_subnet.reload.connected_subnets.count).to eq(1)
        expect(page.title).to eq "Ubicloud - Forbidden"

        visit "#{project.path}#{private_subnet.path}/networking"
        expect(page).to have_no_content "Disconnect"
      end
    end

    describe "rename" do
      it "can rename private subnet" do
        old_name = private_subnet.name
        visit "#{project.path}#{private_subnet.path}/settings"
        fill_in "name", with: "new-name%"
        click_button "Rename"
        expect(page).to have_flash_error("Validation failed for following fields: name")
        expect(page).to have_content("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
        expect(private_subnet.reload.name).to eq old_name

        fill_in "name", with: "new-name"
        click_button "Rename"
        expect(page).to have_flash_notice("Name updated")
        expect(private_subnet.reload.name).to eq "new-name"
        expect(page).to have_content("new-name")
      end

      it "does not show rename option without permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:view"])
        visit "#{project_wo_permissions.path}#{ps_wo_permission.path}/settings"
        expect(page).to have_no_content("Rename")
      end
    end

    describe "delete" do
      it "can delete private subnet" do
        visit "#{project.path}#{private_subnet.path}"
        within("#private-subnet-submenu") { click_link "Settings" }

        click_button "Delete"
        expect(page).to have_flash_notice("Private subnet scheduled for deletion.")

        expect(SemSnap.new(private_subnet.id).set?("destroy")).to be true
      end

      it "can not delete private subnet when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])

        visit "#{project_wo_permissions.path}#{ps_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - dummy-ps-2"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "can not delete private subnet when there are active VMs" do
        private_subnet
        n_id = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32").id
        Prog::Vm::Nexus.assemble("key a", project.id, name: "dummy-vm", nic_id: n_id)

        visit "#{project.path}#{private_subnet.path}/settings"
        click_button "Delete"
        expect(page).to have_flash_error("Private subnet '#{private_subnet.name}' has VMs attached, first, delete them.")
      end
    end

    describe "vpc peering" do
      let(:location) {
        Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "aws-us-west-2", visible: true).tap {
          LocationAz.create(location_id: it.id, az: "a", zone_id: "usw2-az1")
        }
      }

      let(:aws_ps) {
        Prog::Vnet::SubnetNexus.assemble(project.id, name: "aws-ps", location_id: location.id).subject.tap {
          it.private_subnet_aws_resource.update(vpc_id: "vpc-0aaaaaaaaaaaaaaaa")
        }
      }

      let(:tab_path) { "#{project.path}#{aws_ps.path}/vpc-peering" }

      let(:vp) { Prog::Vnet::VpcPeeringNexus.assemble(aws_ps, peer_account_id: "111122223333", peer_vpc_id: "vpc-0bbbbbbbbbbbbbbbb", aws: {peer_region: "eu-central-1"}).subject }

      let(:card) { "#vpc-peering-#{vp.ubid}" }

      before do
        allow(Config).to receive(:vpc_peering_enabled).and_return(true)
        project.set_ff_vpc_peering_aws(true)
      end

      def submenu_links
        page.all("#private-subnet-submenu a").map(&:text)
      end

      def record_connection(expires_at: Time.utc(2026, 10, 30, 12))
        vp.vpc_peering_aws_resource.update(peering_connection_id: "pcx-0123456789abcdef0", requester_account_id: "999988887777", expires_at:)
      end

      def fill_in_request(account: "1111 2222-3333", region: "Europe (Frankfurt) - eu-central-1")
        fill_in "AWS account ID", with: account
        fill_in "VPC ID", with: "vpc-0bbbbbbbbbbbbbbbb"
        select region, from: "Region of your VPC"
        click_button "Send peering request"
      end

      it "shows the tab only while VPC peering is enabled for the project" do
        project.set_ff_vpc_peering_aws(false)
        visit "#{project.path}#{aws_ps.path}/overview"
        expect(submenu_links).to eq ["Overview", "Virtual Machines", "Networking", "Settings"]

        visit tab_path
        expect(page.status_code).to eq(404)

        project.set_ff_vpc_peering_aws(true)
        visit "#{project.path}#{aws_ps.path}/overview"
        expect(submenu_links).to eq ["Overview", "Virtual Machines", "Networking", "VPC Peering", "Settings"]

        within("#private-subnet-submenu") { click_link "VPC Peering" }
        expect(page.title).to eq("Ubicloud - aws-ps")
        expect(page).to have_content "Ubicloud VPC vpc-0aaaaaaaaaaaaaaaa CIDR #{aws_ps.net4} Region us-west-2", normalize_ws: true
        expect(page).to have_content "Your VPC's CIDR blocks must not overlap #{aws_ps.net4}."
        expect(page).to have_content "No VPC peerings yet."
        expect(page).to have_select("Region of your VPC", selected: "US West (Oregon) - us-west-2")
      end

      it "shows a peering while Ubicloud sends the request" do
        vp
        visit tab_path
        within(card) do
          expect(page).to have_content "vpc-0bbbbbbbbbbbbbbbb creating"
          expect(page).to have_content "Account 111122223333, region eu-central-1"
          expect(page).to have_content "Sending the peering request..."
        end

        vp.update(state_message: "Ubicloud has reached the AWS limit for pending peering requests in this region. The request is sent automatically when capacity frees up.")
        page.refresh
        expect(page.find(card)).to have_content "Ubicloud has reached the AWS limit for pending peering requests in this region."
        expect(page.find(card)).to have_no_content "Sending the peering request..."
      end

      it "shows the customer how to accept a request that waits for them" do
        record_connection
        vp.update(state: "waiting_for_peer")
        visit tab_path

        within(card) do
          expect(page).to have_content "vpc-0bbbbbbbbbbbbbbbb waiting_for_peer"
          expect(page).to have_content "Ubicloud sent a peering request pcx-0123456789abcdef0 from VPC vpc-0aaaaaaaaaaaaaaaa (account 999988887777, us-west-2) to your VPC vpc-0bbbbbbbbbbbbbbbb in account 111122223333 (eu-central-1). It expires on 2026-10-30 12:00 UTC."
          expect(page).to have_content "Check that the requester is account 999988887777, VPC vpc-0aaaaaaaaaaaaaaaa, CIDR #{aws_ps.net4}."
          expect(page).to have_content "Ubicloud's AWS account sends peering requests for all Ubicloud customers, so accept only the connection with this exact ID"
          expect(page).to have_content "add a route with destination #{aws_ps.net4} and target peering connection pcx-0123456789abcdef0"
          expect(page).to have_content "allow outbound TCP to #{aws_ps.net4} on those ports and inbound return traffic from #{aws_ps.net4} on ports 1024-65535."
          expect(page).to have_content "Virtual machines have no such hostname: connect to their private IPv4 address, shown on the Virtual Machines tab."
          expect(page).to have_content "Ubicloud checks for your acceptance every 30 seconds"
          expect(page).to have_link "Open in AWS console", href: "https://eu-central-1.console.aws.amazon.com/vpcconsole/home?region=eu-central-1#PeeringConnectionDetails:VpcPeeringConnectionId=pcx-0123456789abcdef0"
        end

        vp.vpc_peering_aws_resource.update(expires_at: nil)
        page.refresh
        expect(page.find(card)).to have_content "(eu-central-1). 1. Accept the request.", normalize_ws: true
        expect(page.find(card)).to have_no_content "It expires on"

        location.update(project_id: project.id, byoc: true)
        page.refresh
        expect(page.find(card)).to have_content "The request comes from the AWS account of this location (999988887777). Accept only the connection with this exact ID"
        expect(page.find(card)).to have_no_content "for all Ubicloud customers"
      end

      it "shows an accepted peering while routes are configured" do
        record_connection
        vp.update(state: "configuring")
        visit tab_path

        expect(page.find(card)).to have_content "Accepted. Ubicloud is adding routes for your VPC's CIDR blocks..."
      end

      it "shows the routed CIDR blocks of an active peering and its warnings" do
        record_connection
        vp.update(state: "active", peer_cidrs: Sequel.pg_array(%w[10.200.0.0/16 10.201.0.0/16], :cidr))
        visit tab_path

        within(card) do
          expect(page).to have_content "vpc-0bbbbbbbbbbbbbbbb active"
          expect(page).to have_content "Peering connection pcx-0123456789abcdef0", normalize_ws: true
          expect(page).to have_content "Routed CIDR blocks 10.200.0.0/16, 10.201.0.0/16", normalize_ws: true
          expect(page).to have_content "Your side of the setup"
          expect(page).to have_content "2. Route traffic to Ubicloud."
          expect(page).to have_no_content "1. Accept the request."
          expect(page).to have_no_css ".bg-yellow-50"
        end

        vp.update(state_message: "Not routed: 8.8.0.0/16.")
        page.refresh
        expect(page.find("#{card} .bg-yellow-50").text).to eq "Not routed: 8.8.0.0/16."

        vp.update(peer_cidrs: Sequel.pg_array([], :cidr))
        page.refresh
        expect(page.find(card)).to have_content "Routed CIDR blocks None", normalize_ws: true
      end

      it "shows why a peering failed and what to do, once" do
        reason = "The peering request was rejected in AWS account 111122223333. Delete this peering and create it again."
        vp.update(state: "failed", state_message: reason)
        visit tab_path

        expect(page.find("#{card} .bg-red-50").text).to eq reason
        expect(page.find(card).text.scan("Delete this peering and create it again.").size).to eq 1
      end

      it "requests a peering from the form" do
        visit tab_path
        fill_in_request

        expect(page).to have_flash_notice("Ubicloud is requesting the peering. Accept it in AWS account 111122223333 when it appears below.")
        expect(page.title).to eq("Ubicloud - aws-ps")
        expect(aws_ps.vpc_peerings.map { [it.peer_account_id, it.peer_vpc_id, it.vpc_peering_aws_resource.peer_region] }).to eq [["111122223333", "vpc-0bbbbbbbbbbbbbbbb", "eu-central-1"]]
        expect(page).to have_content "vpc-0bbbbbbbbbbbbbbbb creating"
      end

      it "keeps the input and shows field errors when the request is invalid" do
        visit tab_path
        fill_in_request(account: "1234")

        expect(page).to have_flash_error("Validation failed for following fields: peer_account_id")
        expect(page.title).to eq("Ubicloud - aws-ps")
        expect(page).to have_content "AWS account ID must be 12 digits, such as 123456789012."
        expect(page).to have_field("AWS account ID", with: "1234")
        expect(page).to have_select("Region of your VPC", selected: "Europe (Frankfurt) - eu-central-1")
        expect(aws_ps.vpc_peerings_dataset.count).to eq 0
      end

      it "shows the error of a crafted region under the region select" do
        visit tab_path
        page.driver.browser.dom.css("option[value=\"eu-central-1\"]").attr("value", "mars-north-1")
        fill_in_request

        expect(page).to have_flash_error("Validation failed for following fields: aws.peer_region")
        expect(page.find_by_id("aws[peer_region]-error").text).to eq "\"mars-north-1\" is not an AWS region. Use a region code such as us-east-1."
        expect(aws_ps.vpc_peerings_dataset.count).to eq 0
      end

      it "flashes a refusal from the business rules" do
        other_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "other-ps", location_id: location.id).subject
        visit tab_path
        5.times { Prog::Vnet::VpcPeeringNexus.assemble(other_ps, peer_account_id: "111122223333", peer_vpc_id: "vpc-0#{it}aaaaaaaaaaaaaaa", aws: {peer_region: "us-west-2"}) }
        fill_in_request

        expect(page).to have_flash_error("This project already has 5 VPC peering requests waiting to be accepted in aws-us-west-2. Accept or delete one first.")
        expect(aws_ps.vpc_peerings_dataset.count).to eq 0
      end

      it "replaces the form at the cap" do
        10.times do
          VpcPeeringAwsResource.create_with_id(VpcPeering.create(private_subnet_id: aws_ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0#{it}aaaaaaaaaaaaaaa"), peer_region: "us-west-2")
        end
        visit tab_path

        expect(page.all("#vpc-peerings .delete-btn").length).to eq 10
        expect(page).to have_content "This subnet has the maximum of 10 VPC peerings."
        expect(page).to have_no_button "Send peering request"
      end

      it "hides the form and delete buttons without PrivateSubnet:edit" do
        vp
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        visit tab_path

        expect(page).to have_content "vpc-0bbbbbbbbbbbbbbbb creating"
        expect(page).to have_no_css ".delete-btn"
        expect(page).to have_no_button "Send peering request"
      end

      it "deletes a peering" do
        vp
        visit tab_path
        expect(page.find("#{card} .delete-btn")["data-confirmation-message"]).to eq "Are you sure you want to delete the VPC peering with vpc-0bbbbbbbbbbbbbbbb? Traffic over it stops at once."
        within(card) { click_button "Delete" }

        expect(page).to have_flash_notice("VPC peering with vpc-0bbbbbbbbbbbbbbbb is being deleted")
        expect(vp.destroy_set?(cached: false)).to be true
        within(card) do
          expect(page).to have_content "vpc-0bbbbbbbbbbbbbbbb deleting"
          expect(page).to have_content "Removing routes and the peering connection..."
          expect(page).to have_no_css ".delete-btn"
        end
      end

      it "refuses to delete the private subnet while it has a VPC peering" do
        vp
        visit "#{project.path}#{aws_ps.path}/settings"
        click_button "Delete"

        expect(page).to have_flash_error("Private subnet 'aws-ps' has VPC peerings, first, delete them.")
        expect(aws_ps.destroy_set?(cached: false)).to be false
      end
    end
  end
end
