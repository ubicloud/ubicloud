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
  end
end
