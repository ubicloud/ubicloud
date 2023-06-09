# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "tag_space" do
  let(:user) { create_account }
  let(:user2) { create_account("user2@example.com") }

  let(:tag_space) { user.create_tag_space_with_default_policy("tag-space-1") }

  let(:tag_space_wo_permissions) { user.create_tag_space_with_default_policy("tag-space-2", policy_body: []) }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/tag-space"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/tag-space/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no tag spaces" do
        expect(Account).to receive(:[]).and_return(user).twice
        expect(user).to receive(:tag_spaces).and_return([])

        visit "/tag-space"

        expect(page.title).to eq("Ubicloud - Tag Spaces")
        expect(page).to have_content "No tag spaces"

        click_link "New Tag Space"
        expect(page.title).to eq("Ubicloud - Create Tag Space")
      end

      it "can not list tag spaces when does not invited" do
        tag_space
        new_tag_space = user2.create_tag_space_with_default_policy("tag-space-3")

        visit "/tag-space"

        expect(page.title).to eq("Ubicloud - Tag Spaces")
        expect(page).to have_content tag_space.name
        expect(page).not_to have_content new_tag_space.name
      end
    end

    describe "create" do
      it "can create new tag space" do
        name = "new-tag-space"
        visit "/tag-space/create"

        expect(page.title).to eq("Ubicloud - Create Tag Space")

        fill_in "Name", with: name
        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content name

        tag_space = TagSpace[name: name]
        expect(tag_space.access_tags.count).to be 2
        expect(tag_space.access_policies.count).to be 1
        expect(tag_space.applied_access_tags.count).to be 1
        expect(user.hyper_tag(tag_space)).to exist
      end
    end

    describe "show - details" do
      it "can show tag space details" do
        tag_space
        visit "/tag-space"

        expect(page.title).to eq("Ubicloud - Tag Spaces")
        expect(page).to have_content tag_space.name

        click_link "Show", href: tag_space.path

        expect(page.title).to eq("Ubicloud - #{tag_space.name}")
        expect(page).to have_content tag_space.name
      end

      it "raises forbidden when does not have permissions" do
        tag_space_wo_permissions
        visit "/tag-space"

        expect(page.title).to eq("Ubicloud - Tag Spaces")
        expect(page).to have_content tag_space_wo_permissions.name

        click_link "Show", href: tag_space_wo_permissions.path

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when virtual machine not exists" do
        visit "/tag-space/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Page not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Page not found"
      end
    end

    describe "show - users" do
      it "can show tag space users" do
        visit tag_space.path

        click_link "Users"

        expect(page.title).to eq("Ubicloud - #{tag_space.name} - Users")
        expect(page).to have_content user.email
      end

      it "raises forbidden when does not have permissions" do
        tag_space_wo_permissions
        visit "#{tag_space_wo_permissions.path}/user"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can invite new user to tag space" do
        visit "#{tag_space.path}/user"

        expect(page).to have_content user.email
        expect(page).not_to have_content user2.email

        fill_in "Email", with: user2.email
        click_button "Invite"

        expect(page).to have_content user.email
        expect(page).to have_content user2.email
        expect(Mail::TestMailer.deliveries.length).to eq 1
        Mail::TestMailer.deliveries.clear
      end

      it "can invite new existing email to tag space and nothing happens" do
        visit "#{tag_space.path}/user"

        expect(page).to have_content user.email

        fill_in "Email", with: "new@example.com"
        click_button "Invite"

        expect(page).to have_content user.email
        expect(page).to have_content "Invitation sent successfully to 'new@example.com'."
        expect(Mail::TestMailer.deliveries.length).to eq 1
        Mail::TestMailer.deliveries.clear
      end

      it "can remove user from tag space" do
        user2.associate_with_tag_space(tag_space)

        visit "#{tag_space.path}/user"

        expect(page).to have_content user.email
        expect(page).to have_content user2.email

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#user-#{user2.ulid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "Removing #{user2.email} from #{tag_space.name}"}.to_json)

        visit "#{tag_space.path}/user"
        expect(page).to have_content user.email
        expect(page).not_to have_content user2.email
      end

      it "raises bad request when it's the last user" do
        user
        visit "#{tag_space.path}/user"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#user-#{user.ulid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "You can't remove the last user from '#{tag_space.name}' tag space. Delete tag space instead."}.to_json)

        visit "#{tag_space.path}/user"
        expect(page).to have_content user.email
      end

      it "raises not found when user not exists" do
        expect(Account).to receive(:[]).and_return(nil).twice

        visit "#{tag_space.path}/user/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Page not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Page not found"
      end
    end

    describe "show - policies" do
      it "can show tag space policy" do
        visit tag_space.path

        click_link "Policy"

        expect(page.title).to eq("Ubicloud - #{tag_space.name} - Policy")
        expect(page).to have_content tag_space.access_policies.first.body.to_json
      end

      it "raises forbidden when does not have permissions" do
        visit "#{tag_space_wo_permissions.path}/policy"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can update policy" do
        current_policy = tag_space.access_policies.first.body
        new_policy = {
          acls: [
            {powers: ["TagSpace:policy"], objects: tag_space.hyper_tag_name, subjects: user.hyper_tag_name}
          ]
        }

        visit "#{tag_space.path}/policy"

        expect(page).to have_content current_policy.to_json

        fill_in "body", with: new_policy.to_json
        click_button "Update"

        expect(page).to have_content new_policy.to_json
      end

      it "can not update policy when it is not valid JSON" do
        current_policy = tag_space.access_policies.first.body

        visit "#{tag_space.path}/policy"

        fill_in "body", with: "{'invalid': 'json',}"
        click_button "Update"

        expect(page).to have_content "The policy isn't a valid JSON object."
        expect(page).to have_content "{'invalid': 'json',}"
        expect(current_policy).to eq(tag_space.access_policies.first.body)
      end

      it "raises not found when access policy not exists" do
        expect(AccessPolicy).to receive(:[]).and_return(nil)

        visit "#{tag_space.path}/policy/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - Page not found")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "Page not found"
      end
    end

    describe "delete" do
      it "can delete tag space" do
        visit tag_space.path

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "'#{tag_space.name}' tag space is deleted."}.to_json)

        expect(TagSpace[tag_space.id]).to be_nil
        expect(AccessTag.where(tag_space_id: tag_space.id).count).to eq(0)
        expect(AccessPolicy.where(tag_space_id: tag_space.id).count).to eq(0)
      end

      it "can not delete tag space when it has resources" do
        Prog::Vm::Nexus.assemble("key", tag_space.id, name: "vm1")

        visit tag_space.path

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.body).to eq({message: "'#{tag_space.name}' tag space has some resources. Delete all related resources first."}.to_json)

        visit "/tag-space"

        expect(page).to have_content tag_space.name
      end

      it "can not delete tag space when does not have permissions" do
        # Give permission to view, so we can see the detail page
        tag_space_wo_permissions.access_policies.first.update(body: {acls: [
          {subjects: user.hyper_tag_name, powers: ["TagSpace:view"], objects: tag_space_wo_permissions.hyper_tag_name}
        ]})

        visit tag_space_wo_permissions.path

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
