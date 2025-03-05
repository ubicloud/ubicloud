# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "aws region" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:aws_region) do
    alc = AwsLocationCredential.create_with_id(
      access_key: "access_key",
      secret_key: "secret_key",
      region_name: "us-east-1",
      project_id: project.id
    )
    Location.create_with_id(
      display_name: "aws-us-east-1",
      name: "#{project.ubid}-aws-us-east-1",
      ui_name: "aws-us-east-1",
      visible: false,
      provider: "aws",
      aws_location_credential_id: alc.id
    )
    alc
  end

  let(:aws_region_wo_permission) {
    alc = AwsLocationCredential.create_with_id(
      access_key: "access_key",
      secret_key: "secret_key",
      region_name: "us-west-1",
      project_id: project_wo_permissions.id
    )
    Location.create_with_id(
      display_name: "aws-us-west-1",
      name: "#{project_wo_permissions.ubid}-aws-us-west-1",
      ui_name: "aws-us-west-1",
      visible: false,
      provider: "aws",
      aws_location_credential_id: alc.id
    )
    alc
  }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/aws-region"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/aws-region/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no aws regions" do
        visit "#{project.path}/aws-region"

        expect(page.title).to eq("Ubicloud - AWS Regions")
        expect(page).to have_content "No AWS Regions"

        click_link "Create AWS Region"
        expect(page.title).to eq("Ubicloud - Create AWS Region")
      end

      it "can not list aws regions when does not have permissions" do
        aws_region
        aws_region_wo_permission
        visit "#{project.path}/aws-region"

        expect(page.title).to eq("Ubicloud - AWS Regions")
        expect(page).to have_content aws_region.location.display_name
        expect(page).to have_no_content aws_region_wo_permission.location.display_name
      end

      it "does not show new/create aws region without AwsLocationCredential:create permissions" do
        visit "#{project.path}/aws-region"
        expect(page).to have_content "Create AWS Region"
        expect(page).to have_content "Get started by creating a new AWS Region."

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["AwsLocationCredential:view"])

        page.refresh
        expect(page).to have_content "No AWS Regions"
        expect(page).to have_content "You don't have permission to create AWS Regions."

        aws_region
        page.refresh
        expect(page).to have_no_content "Create AWS Region"
      end
    end

    describe "create" do
      it "can create new aws region" do
        project
        visit "#{project.path}/aws-region/create"

        expect(page.title).to eq("Ubicloud - Create AWS Region")
        name = "dummy-aws-region"
        fill_in "Ubicloud Region Name", with: name
        fill_in "AWS Access Key", with: "access_key"
        fill_in "AWS Secret Key", with: "secret_key"
        select "us-east-1", from: "AWS Region Name"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - AWS Regions")
        expect(AwsLocationCredential.count).to eq(1)
        expect(AwsLocationCredential.first.project_id).to eq(project.id)
        expect(AwsLocationCredential.first.region_name).to eq("us-east-1")
        expect(AwsLocationCredential.first.access_key).to eq("access_key")
        expect(AwsLocationCredential.first.secret_key).to eq("secret_key")
        expect(AwsLocationCredential.first.location.display_name).to eq(name)
      end

      it "can not create aws region with same name" do
        project
        visit "#{project.path}/aws-region/create"

        expect(page.title).to eq("Ubicloud - Create AWS Region")

        fill_in "Ubicloud Region Name", with: aws_region.location.display_name
        fill_in "AWS Access Key", with: "access_key"
        fill_in "AWS Secret Key", with: "secret_key"
        select "us-east-1", from: "AWS Region Name"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create AWS Region")
        expect(page).to have_flash_error("project_id and region_name is already taken")
      end
    end

    describe "show" do
      it "can show aws location credential details" do
        aws_region
        visit "#{project.path}/aws-region"

        expect(page.title).to eq("Ubicloud - AWS Regions")
        expect(page).to have_content aws_region.location.ui_name

        click_link aws_region.location.ui_name, href: "#{project.path}#{aws_region.path}"

        puts "page:    #{page.inspect}"
        # expect(page.title).to eq("Ubicloud - #{aws_region.location.ui_name}")
        expect(page).to have_content aws_region.location.ui_name
      end

      it "raises not found when aws location credential not exists" do
        visit "#{project.path}/aws-region/eu-central-h1"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    # describe "show nics" do
    #   it "can show nic details" do
    #     private_subnet
    #     n_id = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "dummy-nic",
    #       ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
    #       ipv4_addr: "172.17.226.186/32").id
    #     nic = Nic[n_id]
    #     visit "#{project.path}#{private_subnet.path}"

    #     expect(page.title).to eq("Ubicloud - #{private_subnet.name}")
    #     expect(page).to have_content nic.private_ipv4.network.to_s
    #     expect(page).to have_content nic.private_ipv6.nth(2).to_s
    #   end
    # end

    # describe "show firewalls" do
    #   it "can show attached firewalls" do
    #     private_subnet
    #     fw = Firewall.create_with_id(name: "dummy-fw", description: "dummy-fw", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
    #     fw.associate_with_private_subnet(private_subnet)

    #     visit "#{project.path}#{private_subnet.path}"

    #     expect(page.title).to eq("Ubicloud - #{private_subnet.name}")
    #     expect(page).to have_content fw.name
    #     expect(page).to have_content fw.description
    #   end
    # end

    # describe "connected subnets" do
    #   it "can show connected subnets" do
    #     private_subnet
    #     ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
    #     private_subnet.connect_subnet(ps2)

    #     visit "#{project.path}#{private_subnet.path}"

    #     expect(page).to have_content ps2.name
    #     expect(page.all("a").map(&:text)).to include ps2.name

    #     AccessControlEntry.dataset.destroy
    #     AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"], object_id: private_subnet.id)
    #     page.refresh
    #     expect(page).to have_content ps2.name
    #     expect(page.all("a").map(&:text)).not_to include ps2.name
    #   end

    #   it "can disconnect connected subnet" do
    #     private_subnet
    #     ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
    #     private_subnet.connect_subnet(ps2)

    #     visit "#{project.path}#{private_subnet.path}"

    #     expect(page).to have_content ps2.name

    #     btn = find "#cps-delete-#{ps2.ubid} .delete-btn"
    #     page.driver.post btn["data-url"], {_csrf: btn["data-csrf"]}

    #     expect(private_subnet.reload.connected_subnets.count).to eq(0)
    #   end

    #   it "can connect to a subnet" do
    #     private_subnet
    #     ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
    #     expect(private_subnet.connected_subnets.count).to eq(0)
    #     visit "#{project.path}#{private_subnet.path}"

    #     select ps2.name, from: "connected-subnet-ubid"
    #     click_button "Connect"

    #     expect(private_subnet.reload.connected_subnets.count).to eq(1)
    #   end

    #   it "cannot connect to a subnet when it does not exist" do
    #     private_subnet
    #     ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
    #     visit "#{project.path}#{private_subnet.path}"
    #     ps2.strand.destroy
    #     ps2.destroy
    #     select "dummy-ps-2", from: "connected-subnet-ubid"
    #     click_button "Connect"

    #     expect(page).to have_flash_error("Subnet to be connected not found")
    #   end

    #   it "cannot disconnect a subnet when it does not exist" do
    #     private_subnet
    #     ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID).subject
    #     private_subnet.connect_subnet(ps2)
    #     visit "#{project.path}#{private_subnet.path}"
    #     small_id, large_id = (private_subnet.id < ps2.id) ? [private_subnet.id, ps2.id] : [ps2.id, private_subnet.id]
    #     ConnectedSubnet.where(subnet_id_1: small_id, subnet_id_2: large_id).destroy
    #     ps2.semaphores.map(&:destroy)
    #     ps2.strand.destroy
    #     ps2.destroy

    #     btn = find "#cps-delete-#{ps2.ubid} .delete-btn"
    #     page.driver.post btn["data-url"], {_csrf: btn["data-csrf"]}

    #     expect(page.status_code).to eq(400)
    #     expect(page.body).to eq({error: {code: 400, type: "InvalidRequest", message: "Subnet to be disconnected not found"}}.to_json)
    #   end
    # end

    # describe "delete" do
    #   it "can delete private subnet" do
    #     visit "#{project.path}#{private_subnet.path}"

    #     # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
    #     # UI tests run without a JavaScript enginer.
    #     btn = find ".delete-btn"
    #     page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

    #     expect(SemSnap.new(private_subnet.id).set?("destroy")).to be true
    #   end

    #   it "can not delete private subnet when does not have permissions" do
    #     # Give permission to view, so we can see the detail page
    #     AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])

    #     visit "#{project_wo_permissions.path}#{ps_wo_permission.path}"
    #     expect(page.title).to eq "Ubicloud - dummy-ps-2"

    #     expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
    #   end

    #   it "can not delete private subnet when there are active VMs" do
    #     private_subnet
    #     n_id = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "dummy-nic",
    #       ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
    #       ipv4_addr: "172.17.226.186/32").id
    #     Prog::Vm::Nexus.assemble("key", project.id, name: "dummy-vm", nic_id: n_id)

    #     visit "#{project.path}#{private_subnet.path}"
    #     btn = find ".delete-btn"
    #     Capybara.current_session.driver.header "Accept", "application/json"
    #     response = page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
    #     expect(response).to have_api_error(409, "Private subnet '#{private_subnet.name}' has VMs attached, first, delete them.")
    #   end
    # end
  end
end
