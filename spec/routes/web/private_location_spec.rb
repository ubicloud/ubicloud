# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "location-credential" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:private_location) do
    loc = Location.create(
      display_name: "aws-us-east-1",
      name: "us-east-1",
      ui_name: "aws-us-east-1",
      visible: false,
      provider: "aws",
      project_id: project.id
    )

    LocationCredential.create(
      access_key: "access_key",
      secret_key: "secret_key"
    ) { it.id = loc.id }
    loc
  end

  let(:private_location_wo_permission) {
    loc = Location.create(
      display_name: "aws-us-west-1",
      name: "us-west-1",
      ui_name: "aws-us-west-1",
      visible: false,
      provider: "aws",
      project_id: project_wo_permissions.id
    )

    LocationCredential.create(
      access_key: "access_key",
      secret_key: "secret_key"
    ) { it.id = loc.id }
    loc
  }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/private-location"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/private-location/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "verify sidebar shows private location" do
      it "shows private location" do
        project.set_ff_private_locations(true)
        visit project.path

        expect(page).to have_content "AWS Regions"
      end
    end

    describe "list" do
      it "can list no aws regions" do
        visit "#{project.path}/private-location"

        expect(page.title).to eq("Ubicloud - AWS Regions")
        expect(page).to have_content "No AWS Regions"

        click_link "Create AWS Region"
        expect(page.title).to eq("Ubicloud - Create AWS Region")
      end

      it "can not list aws regions when does not have permissions" do
        private_location
        private_location_wo_permission
        visit "#{project.path}/private-location"

        expect(page.title).to eq("Ubicloud - AWS Regions")
        expect(page).to have_content private_location.display_name
        expect(page).to have_no_content private_location_wo_permission.display_name
      end

      it "does not show new/create aws region without Location:create permissions" do
        visit "#{project.path}/private-location"
        expect(page).to have_content "Create AWS Region"
        expect(page).to have_content "Get started by creating a new AWS Region."

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Location:view"])

        page.refresh
        expect(page).to have_content "No AWS Regions"
        expect(page).to have_content "You don't have permission to create AWS Regions."

        private_location
        page.refresh
        expect(page).to have_no_content "Create AWS Region"
      end
    end

    describe "create" do
      it "can create new aws region" do
        project
        visit "#{project.path}/private-location/create"

        expect(page.title).to eq("Ubicloud - Create AWS Region")
        name = "dummy-private-location"
        fill_in "Ubicloud Region Name", with: name
        fill_in "AWS Access Key", with: "access_key"
        fill_in "AWS Secret Key", with: "secret_key"
        select "us-east-1", from: "AWS Region Name"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - dummy-private-location")
        expect(LocationCredential.count).to eq(1)
        expect(LocationCredential.first.access_key).to eq("access_key")
        expect(LocationCredential.first.secret_key).to eq("secret_key")
        expect(LocationCredential.first.location.display_name).to eq(name)
        expect(LocationCredential.first.location.name).to eq("us-east-1")
        expect(LocationCredential.first.location.project_id).to eq(project.id)
      end

      it "can not create aws region with same display name" do
        project
        visit "#{project.path}/private-location/create"

        expect(page.title).to eq("Ubicloud - Create AWS Region")

        fill_in "Ubicloud Region Name", with: private_location.display_name
        fill_in "AWS Access Key", with: "access_key"
        fill_in "AWS Secret Key", with: "secret_key"
        select "us-east-1", from: "AWS Region Name"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create AWS Region")
        expect(page).to have_flash_error("project_id and display_name is already taken, project_id and ui_name is already taken")
      end
    end

    describe "show" do
      it "can show aws location credential details" do
        private_location
        visit "#{project.path}/private-location"

        expect(page.title).to eq("Ubicloud - AWS Regions")
        expect(page).to have_content private_location.ui_name

        click_link private_location.ui_name, href: "#{project.path}#{private_location.path}"
        # expect(page.title).to eq("Ubicloud - #{private_location.location.ui_name}")
        expect(page).to have_content private_location.ui_name
      end

      it "raises not found when aws location credential not exists" do
        visit "#{project.path}/private-location/eu-central-h1"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "delete" do
      it "can delete aws location credential" do
        visit "#{project.path}#{private_location.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(LocationCredential[private_location.id]).to be_nil
      end

      it "can not delete aws location credential when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Location:view"])

        visit "#{project_wo_permissions.path}#{private_location_wo_permission.path}"
        expect(page.title).to eq "Ubicloud - aws-us-west-1"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "can not delete aws location credential when there are active resources" do
        private_location
        expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
        Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: project.id,
          name: "dummy-postgres",
          location_id: private_location.id,
          target_vm_size: "standard-2",
          target_storage_size_gib: 118
        )

        visit "#{project.path}#{private_location.path}"
        btn = find ".delete-btn"
        Capybara.current_session.driver.header "Accept", "application/json"
        response = page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(response).to have_api_error(409, "Private location '#{private_location.ui_name}' has some resources, first, delete them.")
      end
    end

    describe "update" do
      it "can update aws location credential name" do
        private_location
        visit "#{project.path}#{private_location.path}"
        fill_in "name", with: "new-name"
        click_button "Save"
        expect(page).to have_content "new-name"
      end
    end
  end
end
