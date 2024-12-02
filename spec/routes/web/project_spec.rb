# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "project" do
  let(:user) { create_account }
  let(:user2) { create_account("user2@example.com") }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

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
        user.projects.each { user.dissociate_with_project(_1) }

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
        expect(page).to have_no_content new_project.name
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

    describe "dashboard" do
      it "can view project dashboard always" do
        visit "#{project_wo_permissions.path}/dashboard"

        expect(page.title).to eq("Ubicloud - #{project_wo_permissions.name} Dashboard")
        expect(page).to have_content project_wo_permissions.name
      end

      it "raises forbidden when user isn't added to project" do
        new_project = Project.create_with_id(name: "new-project")
        visit "#{new_project.path}/dashboard"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "not show on sidebar when does not have permissions" do
        visit "#{project_wo_permissions.path}/dashboard"

        within "#desktop-menu" do
          expect { click_link "Users" }.to raise_error Capybara::ElementNotFound
          expect { click_link "Access Policy" }.to raise_error Capybara::ElementNotFound
          expect { click_link "Billing" }.to raise_error Capybara::ElementNotFound
          expect { click_link "Settings" }.to raise_error Capybara::ElementNotFound
        end
      end
    end

    describe "details" do
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

      it "raises not found when project not exists" do
        visit "/project/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end

      it "can update the project name" do
        new_name = "New-Project-Name"
        visit project.path

        fill_in "name", with: new_name
        click_button "Save"

        expect(page).to have_content new_name
        expect(project.reload.name).to eq(new_name)
      end

      it "can not update the project name when does not have permissions" do
        visit project_wo_permissions.path

        expect { click_button "Save" }.to raise_error Capybara::ElementNotFound
      end
    end

    describe "users" do
      it "can show project users" do
        visit project.path

        within "#desktop-menu" do
          click_link "Users"
        end

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

      it "can invite existing user to project with a default policy" do
        visit "#{project.path}/user"

        expect(page).to have_content user.email
        expect(page).to have_no_content user2.email

        fill_in "Email", with: user2.email
        select "Admin", from: "policy"
        click_button "Invite"

        expect(page).to have_content user.email
        expect(page).to have_content user2.email
        expect(page).to have_select("user_policies[#{user2.ubid}]", selected: "Admin")
        expect(Mail::TestMailer.deliveries.length).to eq 1
      end

      it "can invite existing user to project without a default policy" do
        visit "#{project.path}/user"

        fill_in "Email", with: user2.email
        select "No policy", from: "policy"
        click_button "Invite"

        expect(page).to have_content user2.email
        expect(page).to have_select("user_policies[#{user2.ubid}]", selected: nil)
        expect(Mail::TestMailer.deliveries.length).to eq 1
      end

      it "can invite non-existent user to project" do
        visit "#{project.path}/user"
        new_email = "newUpper@example.com"
        expect(page).to have_content user.email

        fill_in "Email", with: new_email
        select "Admin", from: "policy"
        click_button "Invite"

        expect(page).to have_content user.email
        expect(page).to have_content new_email
        expect(page).to have_content "Invitation sent successfully to '#{new_email}'."
        expect(page).to have_select("invitation_policies[#{new_email}]", selected: "Admin")
        expect(Mail::TestMailer.deliveries.length).to eq 1
        expect(ProjectInvitation.where(email: new_email).count).to eq 1

        fill_in "Email", with: new_email.downcase
        click_button "Invite"

        expect(page).to have_content "'#{new_email.downcase}' already invited to join the project."
      end

      it "can remove user from project" do
        user2.associate_with_project(project)
        Authorization::ManagedPolicy::Member.apply(project, [user2])

        visit "#{project.path}/user"

        expect(page).to have_content user.email
        expect(page).to have_content user2.email

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#user-#{user2.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to be_empty

        DB.transaction(rollback: :always) do
          DB[:account_password_hashes].where(id: user2.id).delete(force: true)
          user2.destroy
          page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}, "HTTP_ACCEPT" => "application/json"
          expect(page.status_code).to eq(404)
          expect(JSON.parse(page.body).dig("error", "code")).to eq(404)
        end

        visit "#{project.path}/user"
        expect(page).to have_content user.email
        expect(page.find_by_id("flash-notice").text).to eq("Removed #{user2.email} from #{project.name}")

        visit "#{project.path}/user"
        expect(page).to have_content user.email
        expect(page).to have_no_content user2.email
      end

      it "can update default policy of an user" do
        user2.associate_with_project(project)
        Authorization::ManagedPolicy::Member.apply(project, [user2])
        # Just add a nonexistent subject to it to test edge case
        policy = project.access_policies_dataset.where(name: "member").first
        policy.body["acls"].first["subjects"] << "user/new@test.com"
        policy.modified!(:body)
        policy.save_changes

        visit "#{project.path}/user"

        expect(page).to have_select("user_policies[#{user2.ubid}]", selected: "Member")
        within "form#managed-policy" do
          select "Admin", from: "user_policies[#{user2.ubid}]"
          click_button "Update"
        end
        expect(page).to have_select("user_policies[#{user2.ubid}]", selected: "Admin")
      end

      it "raises bad request when it's the last admin" do
        visit "#{project.path}/user"

        within "form#managed-policy" do
          select "Member", from: "user_policies[#{user.ubid}]"
          click_button "Update"
        end
        expect(page).to have_content "The project must have at least one admin"
        expect(page).to have_select("user_policies[#{user.ubid}]", selected: "Admin")
      end

      it "can remove invited user from project" do
        invited_email = "invited@example.com"
        project.add_invitation(email: invited_email, inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf", expires_at: Time.now + 7 * 24 * 60 * 60)

        visit "#{project.path}/user"
        expect(page).to have_content invited_email

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#invitation-#{invited_email.gsub(/\W+/, "")} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        visit "#{project.path}/user"
        expect(page.find_by_id("flash-notice").text).to eq("Invitation for '#{invited_email}' is removed successfully.")

        visit "#{project.path}/user"
        expect(page).to have_no_content invited_email
        expect { find "#invitation-#{invited_email.gsub(/\W+/, "")} .delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "can update default policy of invited user" do
        invited_email = "invited@example.com"
        project.add_invitation(email: invited_email, policy: "member", inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf", expires_at: Time.now + 7 * 24 * 60 * 60)
        inv2 = project.add_invitation(email: "invited2@example.com", policy: "member", inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf", expires_at: Time.now + 7 * 24 * 60 * 60)

        visit "#{project.path}/user"

        inv2.destroy
        expect(page).to have_select("invitation_policies[#{invited_email}]", selected: "Member")
        within "form#managed-policy" do
          select "Admin", from: "invitation_policies[#{invited_email}]"
          click_button "Update"
        end
        expect(page).to have_select("invitation_policies[#{invited_email}]", selected: "Admin")
      end

      it "can not have more than 50 pending invitations" do
        visit "#{project.path}/user"

        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        expect(project).to receive(:invitations_dataset).and_return(instance_double(Sequel::Dataset, count: 50))
        expect(project).to receive(:invitations_dataset).and_call_original

        fill_in "Email", with: "new@example.com"
        click_button "Invite"

        expect(page).to have_no_content "new@example.com"
        expect(page).to have_content "You can't have more than 50 pending invitations"
      end

      it "raises bad request when it's the last user" do
        user
        visit "#{project.path}/user"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#user-#{user.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(page.status_code).to eq(400)
        expect(page.body).to eq({error: {message: "You can't remove the last user from '#{project.name}' project. Delete project instead."}}.to_json)

        visit "#{project.path}/user"
        expect(page).to have_content user.email
      end

      it "raises not found when user not exists" do
        visit "#{project.path}/user/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "advanced policy" do
      it "can update policy if doesn't have already" do
        new_policy = {
          acls: [
            {actions: ["Project:user"], objects: project.hyper_tag_name, subjects: user.hyper_tag_name}
          ]
        }

        visit "#{project.path}/user/policy"
        within "form#advanced-policy" do
          fill_in "body", with: new_policy.to_json
          click_button "Update"
        end
        expect(page).to have_content new_policy.to_json
        expect(project.access_policies_dataset.where(managed: false).first.body.to_json).to eq(new_policy.to_json)
      end

      it "can update policy existing advanced policy" do
        current_policy = AccessPolicy.create_with_id(project_id: project.id, name: "advanced", body: {acls: [{subjects: user.hyper_tag_name, actions: ["*"], objects: project.hyper_tag_name}]}).body
        new_policy = {
          acls: [
            {actions: ["Project:user"], objects: project.hyper_tag_name, subjects: user.hyper_tag_name}
          ]
        }

        visit "#{project.path}/user/policy"
        expect(page).to have_content current_policy.to_json
        within "form#advanced-policy" do
          fill_in "body", with: new_policy.to_json
          click_button "Update"
        end
        expect(page).to have_content new_policy.to_json
      end

      it "cannot update policy when it is not valid JSON" do
        current_policy = project.access_policies.first.body

        visit "#{project.path}/user/policy"
        within "form#advanced-policy" do
          fill_in "body", with: "{'invalid': 'json',}"
          click_button "Update"
        end

        expect(page).to have_content "The policy isn't a valid JSON object."
        expect(page).to have_content "{'invalid': 'json',}"
        expect(current_policy).to eq(project.access_policies.first.body)
      end

      it "cannot update policy when its root is not JSON object" do
        current_policy = project.access_policies.first.body

        visit "#{project.path}/user/policy"
        within "form#advanced-policy" do
          fill_in "body", with: "[{}, {}]"
          click_button "Update"
        end

        expect(page).to have_content "The policy isn't a valid JSON object."
        expect(page).to have_content "[{}, {}]"
        expect(current_policy).to eq(project.access_policies.first.body)
      end
    end

    describe "delete" do
      it "can delete project" do
        visit project.path

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.status_code).to eq(204)
        expect(Project[project.id].visible).to be_falsey
        expect(AccessTag.where(project_id: project.id).count).to eq(0)
        expect(AccessPolicy.where(project_id: project.id).count).to eq(0)
      end

      it "can not delete project when it has resources" do
        Prog::Vm::Nexus.assemble("key", project.id, name: "vm1")

        visit project.path

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        Capybara.current_session.driver.header "Accept", "application/json"
        response = page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(response).to have_api_error(409, "'#{project.name}' project has some resources. Delete all related resources first.")

        visit "/project"

        expect(page).to have_content project.name
      end

      it "can not delete project when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessPolicy.create_with_id(
          project_id: project_wo_permissions.id,
          name: "only-view",
          body: {acls: [{subjects: user.hyper_tag_name, actions: ["Project:view"], objects: project_wo_permissions.hyper_tag_name}]}
        )

        visit project_wo_permissions.path

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
