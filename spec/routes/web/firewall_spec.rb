# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:firewall) do
    Firewall.create(name: "dummy-fw", description: "dummy-fw", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
  end

  let(:fw_wo_permission) {
    Firewall.create(name: "dummy-fw-2", description: "dummy-fw-2", location_id: Location::HETZNER_FSN1_ID, project_id: project_wo_permissions.id)
  }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/firewall"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/firewall/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no firewalls" do
        visit "#{project.path}/firewall"

        expect(page.title).to eq("Ubicloud - Firewalls")
        expect(page).to have_content "No firewalls"

        click_link "Create Firewall"
        expect(page.title).to eq("Ubicloud - Create Firewall")
      end

      it "can not list firewalls when does not have permissions" do
        firewall
        fw_wo_permission
        visit "#{project.path}/firewall"

        expect(page.title).to eq("Ubicloud - Firewalls")
        expect(page).to have_content firewall.name
        expect(page).to have_no_content fw_wo_permission.name
      end

      it "does not show links to firewalls if user lacks Firewall:view access to them" do
        firewall
        fw = Firewall.create(name: "viewable-fw", description: "viewable-fw", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)

        visit "#{project.path}/firewall"
        link_texts = page.all("a").map(&:text)
        expect(link_texts).to include fw.name
        expect(link_texts).to include firewall.name
        expect(link_texts).to include "Create Firewall"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:view"], object_id: fw.id)
        page.refresh
        expect(page).to have_no_content firewall.name
        link_texts = page.all("a").map(&:text)
        expect(link_texts).to include fw.name
        expect(link_texts).not_to include "Create Firewall"

        click_link fw.name
        expect(page).to have_no_content "Delete firewall"
        expect(page.body).not_to include "form-fw-create-rule"

        fw.add_firewall_rule(cidr: "127.0.0.1")
        fw.add_private_subnet(net6: "::0/24", net4: "127.0.0.0/24", name: "dummy-ps", location_id: Location[name: "hetzner-hel1"].id, project_id: project.id)

        page.refresh
        expect(page.body).not_to include "private_subnet_id"
        expect(page.body).not_to include "/detach-subnet\""
        expect(page.body).not_to include "form-fw-create-rule-"
        expect(page.body).not_to include "/firewall-rule/"
      end

      it "only shows New Firewall link on empty page if user has Firewall:create access" do
        visit "#{project.path}/firewall"
        expect(page.all("a").map(&:text)).to include "Create Firewall"
        expect(page).to have_content "Get started by creating a new firewall."
        expect(page).to have_no_content "You don't have permission to create firewalls."

        AccessControlEntry.dataset.destroy
        page.refresh
        expect(page.all("a").map(&:text)).not_to include "Create Firewall"
        expect(page).to have_content "You don't have permission to create firewalls."
        expect(page).to have_no_content "Get started by creating a new firewall."
      end
    end

    describe "create" do
      it "can create new firewall" do
        project
        visit "#{project.path}/firewall/create"

        expect(page.title).to eq("Ubicloud - Create Firewall")
        name = "dummy-fw"
        fill_in "Name", with: name
        fill_in "Description", with: name

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' is created")
        expect(Firewall.count).to eq(1)
        expect(Firewall.first.project_id).to eq(project.id)
      end

      it "can create new firewall with private subnet" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject

        visit "#{project.path}/firewall/create"

        expect(page.title).to eq("Ubicloud - Create Firewall")
        name = "dummy-fw-1"
        fill_in "Name", with: name
        fill_in "Description", with: name
        select ps.name, from: "private_subnet_id"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' is created")
        fw = Firewall[name: name]
        expect(fw.private_subnets.first.id).to eq(ps.id)

        visit "#{project.path}#{ps.path}/networking"
        expect(page).to have_content name

        visit "#{project.path}#{fw.path}"
        within("#firewall-submenu") { click_link "Networking" }
        expect(page).to have_content ps.name
      end

      it "can not create firewall with invalid name" do
        project
        visit "#{project.path}/firewall/create"

        expect(page.title).to eq("Ubicloud - Create Firewall")

        fill_in "Name", with: "invalid name"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Firewall")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create firewall in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/firewall/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "cannot create firewall when location not exist" do
        visit "#{project.path}/firewall/create"

        fill_in "Name", with: "dummy-fw"
        choose option: Location::HETZNER_FSN1_UBID
        Location[Location::HETZNER_FSN1_ID].destroy

        click_button "Create"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "show" do
      it "can show firewall details" do
        firewall
        visit "#{project.path}/firewall"

        expect(page.title).to eq("Ubicloud - Firewalls")
        expect(page).to have_content firewall.name

        click_link firewall.name, href: "#{project.path}#{firewall.path}"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content firewall.name
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{fw_wo_permission.path}"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when firewall not exists" do
        visit "#{project.path}/location/eu-central-h1/firewall/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "subnets" do
      it "can show" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        firewall.associate_with_private_subnet(ps)

        visit "#{project.path}#{firewall.path}/networking"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content ps.name
      end

      it "can attach subnet" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject

        visit "#{project.path}#{firewall.path}/networking"
        select ps.name, from: "private_subnet_id"
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_flash_notice("Private subnet #{ps.name} is attached to the firewall")
        expect(firewall.private_subnets_dataset.count).to eq(1)

        visit "#{project.path}#{firewall.path}/networking"
        expect(page).to have_content ps.name

        visit "#{project.path}#{ps.path}/networking"
        expect(page).to have_content firewall.name
      end

      it "can not attach subnet when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}#{firewall.path}/networking"
        select "dummy-ps-1", from: "private_subnet_id"
        ps.destroy
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_flash_error("Validation failed for following fields: private_subnet_id")
        expect(page).to have_content("Private subnet with the given id \"#{ps.ubid}\" and the location \"eu-central-h1\" is not found")
        expect(firewall.private_subnets_dataset.count).to eq(0)
      end

      it "can detach subnet" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1111", location_id: Location::HETZNER_FSN1_ID).subject
        expect(page).to have_no_content ps.name

        firewall.associate_with_private_subnet(ps)

        visit "#{project.path}#{firewall.path}/networking"
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_flash_notice("Private subnet #{ps.name} is detached from the firewall")
        expect(firewall.private_subnets_dataset.count).to eq(0)

        visit "#{project.path}#{ps.path}"
        expect(page).to have_no_content firewall.name
      end

      it "can not detach subnet when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        visit "#{project.path}#{firewall.path}/networking"
        select "dummy-ps-1", from: "private_subnet_id"
        click_button "Attach"

        visit "#{project.path}#{firewall.path}/networking"
        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        ps.destroy
        expect(firewall.private_subnets_dataset.count).to eq(0)
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_flash_error("Validation failed for following fields: private_subnet_id")
        expect(page).to have_content("Private subnet with the given id \"#{ps.ubid}\" and the location \"eu-central-h1\" is not found")
        expect(firewall.private_subnets_dataset.count).to eq(0)
      end
    end

    describe "rules" do
      it "can add" do
        visit "#{project.path}#{firewall.path}/networking"

        fill_in "cidr", with: "1.1.1.1/8"
        fill_in "port_range", with: "80"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_flash_notice("Firewall rule is created")
        expect(firewall.firewall_rules_dataset.count).to eq(1)
      end

      it "can not add rule when it is invalid" do
        visit "#{project.path}#{firewall.path}/networking"

        fill_in "cidr", with: "invalid"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content "Invalid CIDR"

        fill_in "cidr", with: "1.1.1.1/32"
        fill_in "port_range", with: "invalid"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content "Invalid port range"

        expect(firewall.firewall_rules_dataset.count).to eq(0)
      end

      it "can delete rule" do
        firewall.insert_firewall_rule("1.0.0.0/8", Sequel.pg_range(80..80))

        visit "#{project.path}#{firewall.path}/networking"

        btn = find "#fwr-delete-#{firewall.firewall_rules.first.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Firewall rule deleted"}.to_json)
        expect(firewall.firewall_rules_dataset.count).to eq(0)

        visit "#{project.path}#{firewall.path}"
        expect(page).to have_no_content "1.0.0.0/8"
      end

      it "accepts delete rule if it's already deleted" do
        firewall.insert_firewall_rule("1.0.0.0/8", Sequel.pg_range(80..80))

        visit "#{project.path}#{firewall.path}/networking"

        firewall.remove_firewall_rule(firewall.firewall_rules.first)
        btn = find "#fwr-delete-#{firewall.firewall_rules.first.ubid} .delete-btn"
        expect { page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]} }.not_to raise_error

        expect(firewall.firewall_rules_dataset.count).to eq(0)
      end

      it "can show firewall rules which have port_range nil" do
        firewall.insert_firewall_rule("1.0.0.0/8", nil)

        visit "#{project.path}#{firewall.path}/networking"

        expect(page.body).to include "fw-create-rule"
        expect(page.body).to include "fwr-delete"
        expect(page.body).to include "fw-attach"

        expect(page).to have_content "1.0.0.0/8"
        expect(page).to have_content "0..65535"

        expect(firewall.firewall_rules_dataset.count).to eq(1)
      end

      it "does not show actions that require edit permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:view"])
        ps = Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
        fw_wo_permission.associate_with_private_subnet(ps)
        fw_wo_permission.insert_firewall_rule("1.0.0.0/8", nil)

        visit "#{project_wo_permissions.path}#{fw_wo_permission.path}/networking"
        expect(page.title).to eq "Ubicloud - dummy-fw-2"
        expect(page.all("#fw-private-subnets a").to_a).to eq []

        expect(page).to have_no_content "Detach"
        expect(page.body).not_to include "fw-create-rule"
        expect(page.body).not_to include "fwr-delete"
        expect(page.body).not_to include "fw-attach"
      end
    end

    describe "delete" do
      it "can delete firewall" do
        visit "#{project.path}#{firewall.path}"
        within("#firewall-submenu") { click_link "Settings" }

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.status_code).to eq(204)
        expect(page.body).to be_empty
        expect(Firewall.count).to eq(0)
      end

      it "can not delete firewall when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:view"])

        visit "#{project_wo_permissions.path}#{fw_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - dummy-fw-2"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
