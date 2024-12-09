# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "access control" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "unauthenticated" do
    it "cannot access without login" do
      visit "#{project.path}/user/access-control"
      expect(page.title).to eq("Ubicloud - Login")

      visit "#{project.path}/user/access-control/entry/new"
      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    it "can view sorted access control entries" do
      visit "#{project.path}/user/access-control"
      project_id = project.id

      expect(page.title).to eq("Ubicloud - project-1 - Access Control")

      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", ""
      ]

      AccessControlEntry.create_with_id(project_id:, subject_id: user.id)
      user.update(name: "Tname")
      page.refresh
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove"
      ]

      st = SubjectTag.create_with_id(project_id:, name: "STest")
      AccessControlEntry.create_with_id(project_id:, subject_id: st.id)
      page.refresh
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove",
        "Edit", "Tag: STest", "All", "All", "Remove"
      ]

      at = ActionTag.create_with_id(project_id:, name: "ATest")
      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id)
      page.refresh
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "All", "Remove",
        "Edit", "Tag: STest", "All", "All", "Remove"
      ]

      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:view"])
      page.refresh
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove",
        "Edit", "Account: Tname", "Project:view", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "All", "Remove",
        "Edit", "Tag: STest", "All", "All", "Remove"
      ]

      ot1 = ObjectTag.create_with_id(project_id:, name: "OTest1")
      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id, object_id: ot1.id)
      page.refresh
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove",
        "Edit", "Account: Tname", "Project:view", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "Tag: OTest1", "Remove",
        "Edit", "Tag: STest", "All", "All", "Remove"
      ]

      ot2 = ObjectTag.create_with_id(project_id:, name: "OTest2")
      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id, object_id: ot2.id)
      page.refresh
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove",
        "Edit", "Account: Tname", "Project:view", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "Tag: OTest1", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "Tag: OTest2", "Remove",
        "Edit", "Tag: STest", "All", "All", "Remove"
      ]

      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id, object_id: ot2.id)
      page.refresh
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove",
        "Edit", "Account: Tname", "Project:view", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "All", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "Tag: OTest1", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "Tag: OTest2", "Remove",
        "Edit", "Account: Tname", "Tag: ATest", "Tag: OTest2", "Remove",
        "Edit", "Tag: STest", "All", "All", "Remove"
      ]
    end

    it "does not show access control entries for tokens" do
      AccessControlEntry.create_with_id(project_id: project.id, subject_id: ApiKey.create_personal_access_token(user).id)

      visit "#{project.path}/user/access-control"
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", ""
      ]
    end

    it "can create access control entries" do
      visit "#{project.path}/user/access-control"
      user.update(name: "Tname")
      click_link "Create Access Control Entry"
      expect(page.title).to eq "Ubicloud - project-1 - Create Access Control Entry"
      select "Tname"
      click_button "Create Access Control Entry"
      expect(find_by_id("flash-notice").text).to include("Access control entry created successfully")

      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove"
      ]

      project_id = project.id
      SubjectTag.create_with_id(project_id:, name: "STest")
      ActionTag.create_with_id(project_id:, name: "ATest")
      ObjectTag.create_with_id(project_id:, name: "OTest")
      click_link "Create Access Control Entry"
      select "STest"
      select "ATest"
      select "OTest"
      click_button "Create Access Control Entry"

      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Account: Tname", "All", "All", "Remove",
        "Edit", "Tag: STest", "Tag: ATest", "Tag: OTest", "Remove"
      ]
    end

    it "can update access control entries" do
      AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id)
      SubjectTag.create_with_id(project_id: project.id, name: "STest")
      visit "#{project.path}/user/access-control"
      click_link "Edit"
      expect(page.title).to eq "Ubicloud - project-1 - Update Access Control Entry"
      select "STest"
      click_button "Update Access Control Entry"
      expect(find_by_id("flash-notice").text).to include("Access control entry updated successfully")

      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", "",
        "Edit", "Tag: STest", "All", "All", "Remove"
      ]
    end

    it "can delete access control entries" do
      AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id)
      visit "#{project.path}/user/access-control"
      btn = find ".delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

      visit "#{project.path}/user/access-control"
      expect(find_by_id("flash-notice").text).to include("Access control entry deleted successfully")
      expect(page.all("table#access-control-entries td").map(&:text)).to eq [
        "", "Tag: Admin", "All", "All", ""
      ]
    end

    it "shows not found page for invalid access control entries" do
      ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id)
      visit "#{project.path}/user/access-control"
      ace.destroy
      click_link "Edit"
      expect(page.title).to eq "Ubicloud - ResourceNotFound"
    end

    it "cannot create access control entries for tokens" do
      # Create subject tag with the same id as token to avoid need to muck with the UI
      SubjectTag.create(project_id: project.id, name: "STest") { |st| st.id = ApiKey.create_personal_access_token(user).id }
      visit "#{project.path}/user/access-control"
      click_link "Create Access Control Entry"
      select "STest"
      click_button "Create Access Control Entry"
      expect(page.status_code).to eq 403
    end

    it "cannot create access control entries for the Admin subject Tag" do
      SubjectTag.where(project_id: project.id, name: "Admin").update(name: "Temp")
      visit "#{project.path}/user/access-control"
      click_link "Create Access Control Entry"
      select "Temp"
      SubjectTag.where(project_id: project.id, name: "Temp").update(name: "Admin")
      click_button "Create Access Control Entry"
      expect(page.status_code).to eq 403
    end

    %w[subject action object].each do |type|
      cap_type = type.capitalize
      model = Object.const_get(:"#{cap_type}Tag")

      it "can view #{type} tags" do
        visit "#{project.path}/user/access-control"
        click_link cap_type
        expect(page.title).to eq "Ubicloud - project-1 - #{cap_type} Tags"
        tds = page.all("table#tag-list td").map(&:text)

        if type == "subject"
          expect(tds).to eq ["Edit Membership", "Admin", ""]
        else
          expect(tds).to eq []
        end

        model.create_with_id(project_id: project.id, name: "test-#{type}")
        page.refresh
        tds = page.all("table#tag-list td").map(&:text)

        if type == "subject"
          expect(tds).to eq [
            "Edit Membership", "Admin", "",
            "Edit Membership", "test-subject", "Remove"
          ]
        else
          expect(tds).to eq ["Edit Membership", "test-#{type}", "Remove"]
        end
      end

      it "can create #{type} tag" do
        visit "#{project.path}/user/access-control/tag/#{type}"
        click_link "Create #{cap_type} Tag"
        expect(page.title).to eq "Ubicloud - project-1 - Create #{cap_type} Tag"
        fill_in "Name", with: "-"
        click_button "Create"
        expect(find_by_id("flash-error").text).to eq "name must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number"

        name = "test-#{type}"
        fill_in "Name", with: name
        click_button "Create"
        expect(model[project_id: project.id, name:]).not_to be_nil
        expect(find_by_id("flash-notice").text).to eq "#{cap_type} tag created successfully"
        expect(page.title).to eq "Ubicloud - project-1 - #{cap_type} Tags"
        expect(page.html).to include name
      end

      it "can rename #{type} tag" do
        name = "test-#{type}"
        model.create_with_id(project_id: project.id, name:)
        visit "#{project.path}/user/access-control/tag/#{type}"
        click_link name

        expect(page.title).to eq "Ubicloud - project-1 - Update #{cap_type} Tag"
        fill_in "Name", with: "-"
        click_button "Update"
        expect(find_by_id("flash-error").text).to eq "name must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number"

        old_name = name
        name = "test2-#{type}"
        fill_in "Name", with: name
        click_button "Update"
        expect(model[project_id: project.id, name: old_name]).to be_nil
        expect(model[project_id: project.id, name:]).not_to be_nil
        expect(find_by_id("flash-notice").text).to eq "#{cap_type} tag name updated successfully"
        expect(page.title).to eq "Ubicloud - project-1 - #{cap_type} Tags"
        expect(page.html).to include name
        expect(page.html).not_to include old_name
      end

      it "can delete #{type} tag" do
        name = "test-#{type}"
        model.create_with_id(project_id: project.id, name:)
        visit "#{project.path}/user/access-control/tag/#{type}"

        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(model[project_id: project.id, name:]).to be_nil

        visit "#{project.path}/user/access-control/tag/#{type}"
        expect(find_by_id("flash-notice").text).to eq "#{cap_type} tag deleted successfully"
      end

      it "can view members of #{type} tag" do
        Account.first.update(name: "test-account") if type == "subject"
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        visit "#{project.path}/user/access-control/tag/#{type}"
        page.find("##{tag1.ubid}-edit a").click

        expect(page.title).to eq "Ubicloud - project-1 - Update #{cap_type} Tag Membership"
        expect(page.html).not_to include "Current Members of #{cap_type} Tag"
        default = lambda do
          case type
          when "subject"
            expect(page.all("table#tag-membership-add td").map(&:text)).to eq ["test-account", ""]
          when "action"
            expect(page.all("table#tag-membership-add td").map(&:text)).to eq ActionType.map(&:name).sort.flat_map { [_1, ""] }
          else
            expect(page.html).not_to include "Add Members to #{cap_type} Tag"
          end
        end
        default.call

        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        page.refresh
        expect(page.html).not_to include "Current Members of #{cap_type} Tag"
        case type
        when "subject"
          expect(page.all("table#tag-membership-add td").map(&:text)).to eq ["other-subject", "", "test-account", ""]
        when "action"
          expect(page.all("table#tag-membership-add td").map(&:text)).to eq ["other-action", ""].concat ActionType.map(&:name).sort.flat_map { [_1, ""] }
        else
          expect(page.all("table#tag-membership-add td").map(&:text)).to eq ["other-object", ""]
        end

        tag1.add_member(tag2.id)
        page.refresh
        expect(page.html).to match(/Current\s*Members\s+of\s+#{cap_type}\s+Tag/)
        expect(page.all("table#tag-membership-remove td").map(&:text)).to eq ["Tag: other-#{type}", ""]
        default.call
      end

      it "can add members to #{type} tag" do
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}/membership"

        find("##{tag2.ubid} input").check
        click_button "Add Members"
        expect(tag1.member_ids).to include tag2.id
        expect(page.title).to eq "Ubicloud - project-1 - Update #{cap_type} Tag Membership"
        expect(find_by_id("flash-notice").text).to eq "1 members added to #{type} tag"
      end

      it "handles errors when adding members to #{type} tag" do
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}/membership"

        tag1.add_member(tag2.id)
        find("##{tag2.ubid} input").check
        click_button "Add Members"
        expect(tag1.member_ids).to include tag2.id
        expect(page.title).to eq "Ubicloud - project-1 - Update #{cap_type} Tag Membership"
        expect(find_by_id("flash-error").text).to eq "No change in membership: 1 members already in tag"
      end

      it "can remove members from #{type} tag" do
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        tag1.add_member(tag2.id)
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}/membership"

        find("##{tag2.ubid} input").check
        click_button "Remove Members"
        expect(tag1.member_ids).to be_empty
        expect(page.title).to eq "Ubicloud - project-1 - Update #{cap_type} Tag Membership"
        expect(find_by_id("flash-notice").text).to eq "1 members removed from #{type} tag"
      end
    end

    it "does not show ApiKeys on subject tag membership page" do
      tag = SubjectTag.create_with_id(project_id: project.id, name: "test-subject")
      api_key = ApiKey.create_personal_access_token(user, project: project)
      tag.add_member(api_key.id)
      visit "#{project.path}/user/access-control/tag/subject/#{tag.ubid}/membership"
      expect(page.html).not_to include "Current Members of Subject Tag"
    end

    it "cannot delete Admin subject tag" do
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      admin.update(name: "not-Admin")
      visit "#{project.path}/user/access-control/tag/subject"

      admin.update(name: "Admin")
      btn = find ".delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
      expect(SubjectTag[project_id: project.id, name: "Admin"]).not_to be_nil

      visit "#{project.path}/user/access-control/tag/subject"
      expect(find_by_id("flash-error").text).to eq "Cannot modify Admin subject tag"
    end

    it "cannot rename Admin subject tag" do
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      visit "#{project.path}/user/access-control/tag/subject/#{admin.ubid}"
      expect(find_by_id("flash-error").text).to eq "Cannot modify Admin subject tag"

      admin.update(name: "not-Admin")
      visit "#{project.path}/user/access-control/tag/subject/#{admin.ubid}"
      admin.update(name: "Admin")
      fill_in "Name", with: "not-Admin"
      click_button "Update"
      expect(find_by_id("flash-error").text).to eq "Cannot modify Admin subject tag"
    end

    it "cannot add Admin subject tag to another subject tag" do
      tag = SubjectTag.create_with_id(project_id: project.id, name: "test-subject")
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      admin.update(name: "not-Admin")
      visit "#{project.path}/user/access-control/tag/subject/#{tag.ubid}/membership"
      admin.update(name: "Admin")
      find("##{admin.ubid} input").check
      click_button "Add Members"
      expect(find_by_id("flash-error").text).to eq "No change in membership: cannot include Admin subject tag in another tag, 1 members not valid"
    end

    it "cannot remove all accounts from Admin subject tag" do
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      visit "#{project.path}/user/access-control/tag/subject/#{admin.ubid}/membership"
      check "remove[]"
      click_button "Remove Members"
      expect(find_by_id("flash-error").text).to eq "Members not removed from tag: must keep at least one account in Admin subject tag"
    end

    it "handles serialization failure when adding members" do
      tag1 = SubjectTag.create_with_id(project_id: project.id, name: "test-subject")
      tag2 = SubjectTag.create_with_id(project_id: project.id, name: "other-subject")
      visit "#{project.path}/user/access-control/tag/subject/#{tag1.ubid}/membership"

      find("##{tag2.ubid} input").check
      5.times do
        expect(UBID).to receive(:class_match?).and_raise(Sequel::SerializationFailure)
        click_button "Add Members"
        expect(find_by_id("flash-error").text).to eq "There was a temporary error attempting to make this change, please try again."
      end

      expect(UBID).to receive(:class_match?).and_return(false)
      click_button "Add Members"
      expect(tag1.member_ids).to include tag2.id
      expect(page.title).to eq "Ubicloud - project-1 - Update Subject Tag Membership"
      expect(find_by_id("flash-notice").text).to eq "1 members added to subject tag"
    end
  end
end
