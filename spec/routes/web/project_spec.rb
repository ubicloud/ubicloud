# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "project" do
  let(:user) { create_account }
  let(:user2) { create_account("user2@example.com") }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/project"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/project/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no projects" do
        expect(Account).to receive(:[]).and_return(user).twice
        expect(user).to receive(:projects).and_return([]).at_least(1)

        visit "/project"

        expect(page.title).to eq("Ubicloud - Projects")
        expect(page).to have_content "No projects"

        click_link "New Project"
        expect(page.title).to eq("Ubicloud - Create Project")
      end

      it "can not list projects when does not invited" do
        project
        new_project = user2.create_project_with_default_policy("project-3")

        visit "/project"

        expect(page.title).to eq("Ubicloud - Projects")
        expect(page).to have_content project.name
        expect(page).not_to have_content new_project.name
      end
    end

    describe "create" do
      it "can create new project" do
        name = "new-project"
        visit "/project/create"

        expect(page.title).to eq("Ubicloud - Create Project")

        fill_in "Name", with: name
        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content name

        project = Project[name: name]
        expect(project.access_tags.count).to be 2
        expect(project.access_policies.count).to be 1
        expect(project.applied_access_tags.count).to be 1
        expect(user.hyper_tag(project)).to exist
      end
    end

    it "can view project dashboard" do
      visit "#{project.path}/dashboard"

      expect(page.title).to eq("Ubicloud - #{project.name} Dashboard")
      expect(page).to have_content project.name
    end

    describe "show - details" do
      it "can show project details" do
        project
        visit "/project"

        expect(page.title).to eq("Ubicloud - Projects")
        expect(page).to have_content project.name

        click_link "Show", href: project.path

        expect(page.title).to eq("Ubicloud - #{project.name}")
        expect(page).to have_content project.name
      end

      it "raises forbidden when does not have permissions" do
        project_wo_permissions
        visit "/project"

        expect(page.title).to eq("Ubicloud - Projects")
        expect(page).to have_content project_wo_permissions.name

        click_link "Show", href: project_wo_permissions.path

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when virtual machine not exists" do
        visit "/project/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Resource not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Resource not found"
      end
    end

    describe "show - users" do
      it "can show project users" do
        visit project.path

        click_link "Users"

        expect(page.title).to eq("Ubicloud - #{project.name} - Users")
        expect(page).to have_content user.email
      end

      it "raises forbidden when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/user"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can invite new user to project" do
        visit "#{project.path}/user"

        expect(page).to have_content user.email
        expect(page).not_to have_content user2.email

        fill_in "Email", with: user2.email
        click_button "Invite"

        expect(page).to have_content user.email
        expect(page).to have_content user2.email
        expect(Mail::TestMailer.deliveries.length).to eq 1
      end

      it "can invite new existing email to project and nothing happens" do
        visit "#{project.path}/user"

        expect(page).to have_content user.email

        fill_in "Email", with: "new@example.com"
        click_button "Invite"

        expect(page).to have_content user.email
        expect(page).to have_content "Invitation sent successfully to 'new@example.com'."
        expect(Mail::TestMailer.deliveries.length).to eq 1
      end

      it "can remove user from project" do
        user2.associate_with_project(project)

        visit "#{project.path}/user"

        expect(page).to have_content user.email
        expect(page).to have_content user2.email

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#user-#{user2.ulid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Removing #{user2.email} from #{project.name}"}.to_json)

        visit "#{project.path}/user"
        expect(page).to have_content user.email
        expect(page).not_to have_content user2.email
      end

      it "raises bad request when it's the last user" do
        user
        visit "#{project.path}/user"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#user-#{user.ulid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "You can't remove the last user from '#{project.name}' project. Delete project instead."}.to_json)

        visit "#{project.path}/user"
        expect(page).to have_content user.email
      end

      it "raises not found when user not exists" do
        visit "#{project.path}/user/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Resource not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Resource not found"
      end
    end

    describe "show - policies" do
      it "can show project policy" do
        visit project.path

        click_link "Policy"

        expect(page.title).to eq("Ubicloud - #{project.name} - Policy")
        expect(page).to have_content project.access_policies.first.body.to_json
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}/policy"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can update policy" do
        current_policy = project.access_policies.first.body
        new_policy = {
          acls: [
            {actions: ["Project:policy"], objects: project.hyper_tag_name, subjects: user.hyper_tag_name}
          ]
        }

        visit "#{project.path}/policy"

        expect(page).to have_content current_policy.to_json

        fill_in "body", with: new_policy.to_json
        click_button "Update"

        expect(page).to have_content new_policy.to_json
      end

      it "can not update policy when it is not valid JSON" do
        current_policy = project.access_policies.first.body

        visit "#{project.path}/policy"

        fill_in "body", with: "{'invalid': 'json',}"
        click_button "Update"

        expect(page).to have_content "The policy isn't a valid JSON object."
        expect(page).to have_content "{'invalid': 'json',}"
        expect(current_policy).to eq(project.access_policies.first.body)
      end

      it "can not update policy when its root is not JSON object" do
        current_policy = project.access_policies.first.body

        visit "#{project.path}/policy"

        fill_in "body", with: "[{}, {}]"
        click_button "Update"

        expect(page).to have_content "The policy isn't a valid JSON object."
        expect(page).to have_content "[{}, {}]"
        expect(current_policy).to eq(project.access_policies.first.body)
      end

      it "raises not found when access policy not exists" do
        expect(AccessPolicy).to receive(:[]).and_return(nil)

        visit "#{project.path}/policy/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Resource not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Resource not found"
      end
    end

    describe "delete" do
      it "can delete project" do
        visit project.path

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "'#{project.name}' project is deleted."}.to_json)

        expect(Project[project.id]).to be_nil
        expect(AccessTag.where(project_id: project.id).count).to eq(0)
        expect(AccessPolicy.where(project_id: project.id).count).to eq(0)
      end

      it "can not delete project when it has resources" do
        Prog::Vm::Nexus.assemble("key", project.id, name: "vm1")

        visit project.path

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "'#{project.name}' project has some resources. Delete all related resources first."}.to_json)

        visit "/project"

        expect(page).to have_content project.name
      end

      it "can not delete project when does not have permissions" do
        # Give permission to view, so we can see the detail page
        project_wo_permissions.access_policies.first.update(body: {acls: [
          {subjects: user.hyper_tag_name, actions: ["Project:view"], objects: project_wo_permissions.hyper_tag_name}
        ]})

        visit project_wo_permissions.path

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
