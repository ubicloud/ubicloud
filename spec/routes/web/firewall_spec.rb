# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:firewall) do
    fw = Firewall.create_with_id(name: "dummy-fw", description: "dummy-fw", location: "hetzner-hel1")
    fw.associate_with_project(project)
    fw
  end

  let(:fw_wo_permission) {
    fw = Firewall.create_with_id(name: "dummy-fw-2", description: "dummy-fw-2", location: "hetzner-hel1")
    fw.associate_with_project(project_wo_permissions)
    fw
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

        click_link "New Firewall"
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
        expect(page).to have_content "'#{name}' is created"
        expect(Firewall.count).to eq(1)
        expect(Firewall.first.projects.first.id).to eq(project.id)
      end

      it "can create new firewall with private subnet" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject

        visit "#{project.path}/firewall/create"

        expect(page.title).to eq("Ubicloud - Create Firewall")
        name = "dummy-fw-1"
        fill_in "Name", with: name
        fill_in "Description", with: name
        select ps.name, from: "private-subnet-id"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' is created"
        fw = Firewall[name: name]
        expect(fw.private_subnets.first.id).to eq(ps.id)

        visit "#{project.path}#{ps.path}"
        expect(page).to have_content name

        visit "#{project.path}#{fw.path}"
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
        visit "#{project.path}/location/hetzner-hel1/firewall/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "subnets" do
      it "can show" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject
        firewall.associate_with_private_subnet(ps)

        visit "#{project.path}#{firewall.path}"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content ps.name
      end

      it "can attach subnet" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject

        visit "#{project.path}#{firewall.path}"
        select ps.name, from: "private-subnet-id"
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content "Private subnet is attached to the firewall"
        expect(firewall.private_subnets_dataset.count).to eq(1)

        visit "#{project.path}#{firewall.path}"
        expect(page).to have_content ps.name

        visit "#{project.path}#{ps.path}"
        expect(page).to have_content firewall.name
      end

      it "can not attach subnet when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject
        visit "#{project.path}#{firewall.path}"
        select "dummy-ps-1", from: "private-subnet-id"
        ps.destroy
        click_button "Attach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content "Private subnet not found"
        expect(firewall.private_subnets_dataset.count).to eq(0)
      end

      it "can detach subnet" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1111", location: "hetzner-hel1").subject
        expect(page).to have_no_content ps.name

        firewall.associate_with_private_subnet(ps)

        visit "#{project.path}#{firewall.path}"
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content "Private subnet #{ps.name} is detached from the firewall"
        expect(firewall.private_subnets_dataset.count).to eq(0)

        visit "#{project.path}#{ps.path}"
        expect(page).to have_no_content firewall.name
      end

      it "can not detach subnet when it does not exist" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject
        visit "#{project.path}#{firewall.path}"
        select "dummy-ps-1", from: "private-subnet-id"
        click_button "Attach"
        visit "#{project.path}#{firewall.path}"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(firewall.private_subnets_dataset.count).to eq(1)
        ps.destroy
        click_button "Detach"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content "Private subnet not found"
        expect(firewall.private_subnets_dataset.count).to eq(0)
      end
    end

    describe "rules" do
      it "can add" do
        visit "#{project.path}#{firewall.path}"

        fill_in "cidr", with: "1.1.1.1/8"
        fill_in "port_range", with: "80"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{firewall.name}")
        expect(page).to have_content "Firewall rule is created"
        expect(firewall.firewall_rules_dataset.count).to eq(1)
      end

      it "can not add rule when it is invalid" do
        visit "#{project.path}#{firewall.path}"

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

        visit "#{project.path}#{firewall.path}"

        btn = find "#fwr-delete-#{firewall.firewall_rules.first.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Firewall rule deleted"}.to_json)
        expect(firewall.firewall_rules_dataset.count).to eq(0)

        visit "#{project.path}#{firewall.path}"
        expect(page).to have_no_content "1.0.0.0/8"
      end

      it "accepts delete rule if it's already deleted" do
        firewall.insert_firewall_rule("1.0.0.0/8", Sequel.pg_range(80..80))

        visit "#{project.path}#{firewall.path}"

        firewall.remove_firewall_rule(firewall.firewall_rules.first)
        btn = find "#fwr-delete-#{firewall.firewall_rules.first.ubid} .delete-btn"
        expect { page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]} }.not_to raise_error

        expect(firewall.firewall_rules_dataset.count).to eq(0)
      end

      it "can show firewall rules which have port_range nil" do
        firewall.insert_firewall_rule("1.0.0.0/8", nil)

        visit "#{project.path}#{firewall.path}"

        expect(page).to have_content "1.0.0.0/8"
        expect(page).to have_content "0..65535"

        expect(firewall.firewall_rules_dataset.count).to eq(1)
      end
    end

    describe "delete" do
      it "can delete firewall" do
        visit "#{project.path}#{firewall.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Deleting #{firewall.name}"}.to_json)
        expect(Firewall.count).to eq(0)
      end

      it "can not delete firewall when does not have permissions" do
        # Give permission to view, so we can see the detail page
        project_wo_permissions.access_policies.first.update(body: {
          acls: [
            {subjects: user.hyper_tag_name, actions: ["Firewall:view"], objects: project_wo_permissions.hyper_tag_name}
          ]
        })

        visit "#{project_wo_permissions.path}#{fw_wo_permission.path}"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
