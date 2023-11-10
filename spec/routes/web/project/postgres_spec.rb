# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "postgres" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:pg) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: "hetzner-hel1",
      server_name: "pg-with-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100
    ).subject
  end

  let(:pg_wo_permission) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project_wo_permissions.id,
      location: "hetzner-hel1",
      server_name: "pg-without-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100
    ).subject
  end

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/postgres"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/postgres/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated but without feature flag" do
    before do
      postgres_project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
      login(user.email)
    end

    it "cannot list postgres databases" do
      visit "#{project.path}/postgres"
      expect(page.title).to eq("Ubicloud - Resource not found")
    end

    it "cannot create postgres databases" do
      visit "#{project.path}/postgres/create"
      expect(page.title).to eq("Ubicloud - Resource not found")
    end

    it "cannot show postgres databases" do
      visit "#{project.path}#{pg.path}"
      expect(page.title).to eq("Ubicloud - Resource not found")
    end
  end

  describe "authenticated" do
    before do
      postgres_project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
      login(user.email)
      project.set_enable_postgres(true)
      project_wo_permissions.set_enable_postgres(true)
    end

    describe "list" do
      it "can list when there is no postgres databases" do
        visit "#{project.path}/postgres"

        expect(page.title).to eq("Ubicloud - PostgreSQL Databases")
        expect(page).to have_content "No PostgreSQL databases"

        click_link "New PostgreSQL Database"
        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
      end

      it "can list only the postgres databases which has permissions to" do
        pg
        pg_wo_permission
        visit "#{project.path}/postgres"

        expect(page.title).to eq("Ubicloud - PostgreSQL Databases")
        expect(page).to have_content pg.server_name
        expect(page).not_to have_content pg_wo_permission.server_name
      end
    end

    describe "create" do
      it "can create new PostgreSQL database" do
        visit "#{project.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: "hetzner-hel1"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(PostgresResource.count).to eq(1)
        expect(PostgresResource.first.projects.first.id).to eq(project.id)
      end

      it "can not create PostgreSQL database with invalid name" do
        visit "#{project.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")

        fill_in "Name", with: "invalid name"
        choose option: "hetzner-hel1"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create PostgreSQL database with same name" do
        visit "#{project.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")

        fill_in "Name", with: pg.server_name
        choose option: "hetzner-hel1"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        expect(page).to have_content "name is already taken"
      end

      it "can not create PostgreSQL database if project has no valid payment method" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

        visit "#{project.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        expect(page).to have_content "Project doesn't have valid billing information"

        fill_in "Name", with: "new-pg-db"
        choose option: "hetzner-hel1"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        expect(page).to have_content "Project doesn't have valid billing information"
      end

      it "can not select invisible location" do
        visit "#{project.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")

        expect { choose option: "github-runners" }.to raise_error Capybara::ElementNotFound
      end

      it "can not create PostgreSQL database in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end
    end

    describe "show" do
      it "can show PostgreSQL database details" do
        pg
        visit "#{project.path}/postgres"

        expect(page.title).to eq("Ubicloud - PostgreSQL Databases")
        expect(page).to have_content pg.server_name

        click_link "Show", href: "#{project.path}#{pg.path}"

        expect(page.title).to eq("Ubicloud - #{pg.server_name}")
        expect(page).to have_content pg.server_name
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when PostgreSQL database not exists" do
        visit "#{project.path}/location/hetzner-hel1/postgres/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Resource not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Resource not found"
      end
    end

    describe "delete" do
      it "can delete PostgreSQL database" do
        visit "#{project.path}#{pg.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Deleting #{pg.server_name}"}.to_json)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "can not delete PostgreSQL database when does not have permissions" do
        # Give permission to view, so we can see the detail page
        project_wo_permissions.access_policies.first.update(body: {
          acls: [
            {subjects: user.hyper_tag_name, actions: ["Postgres:view"], objects: project_wo_permissions.hyper_tag_name}
          ]
        })

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
