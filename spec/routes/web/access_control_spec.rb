# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "access control" do
  let(:user) { create_account }
  let(:project) { user.projects.first }

  describe "unauthenticated" do
    it "cannot access without login" do
      visit "#{project.path}/user/access-control"
      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    # Show the displayed access control entries, except for the Admin one
    def displayed_access_control_entries
      page.all("table#access-control-entries .existing-aces-view td.values").map(&:text) +
        page.all("table#access-control-entries .existing-aces select")
          .map { |select| select.all("option[selected]")[0] || select.first("option") }
          .map(&:text)
    end

    before do
      login(user.email)
    end

    it "can view sorted access control entries" do
      project_id = project.id
      AccessControlEntry.where(project_id:, action_id: Sequel::NOTNULL).destroy
      visit "#{project.path}/user/access-control"

      expect(page.title).to eq("Ubicloud - Default - Access Control")

      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All"
      ]

      ace = AccessControlEntry.create_with_id(project_id:, subject_id: user.id)
      user.update(name: "Tname")
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects"
      ]

      st = SubjectTag.create_with_id(project_id:, name: "STest")
      AccessControlEntry.create_with_id(project_id:, subject_id: st.id)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "STest", "All Actions", "All Objects"
      ]

      at = ActionTag.create_with_id(project_id:, name: "ATest")
      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "ATest", "All Objects",
        "STest", "All Actions", "All Objects"
      ]

      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:view"])
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "Project:view", "All Objects",
        "Tname", "ATest", "All Objects",
        "STest", "All Actions", "All Objects"
      ]

      ot1 = ObjectTag.create_with_id(project_id:, name: "OTest1")
      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id, object_id: ot1.id)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "Project:view", "All Objects",
        "Tname", "ATest", "All Objects",
        "Tname", "ATest", "OTest1",
        "STest", "All Actions", "All Objects"
      ]

      ot2 = ObjectTag.create_with_id(project_id:, name: "OTest2")
      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id, object_id: ot2.id)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "Project:view", "All Objects",
        "Tname", "ATest", "All Objects",
        "Tname", "ATest", "OTest1",
        "Tname", "ATest", "OTest2",
        "STest", "All Actions", "All Objects"
      ]

      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id, object_id: ot2.id)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "Project:view", "All Objects",
        "Tname", "ATest", "All Objects",
        "Tname", "ATest", "OTest1",
        "Tname", "ATest", "OTest2",
        "Tname", "ATest", "OTest2",
        "STest", "All Actions", "All Objects"
      ]

      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: ActionTag[project_id: nil, name: "Member"].id, object_id: ot2.id)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "Member", "OTest2",
        "Tname", "Project:view", "All Objects",
        "Tname", "ATest", "All Objects",
        "Tname", "ATest", "OTest1",
        "Tname", "ATest", "OTest2",
        "Tname", "ATest", "OTest2",
        "STest", "All Actions", "All Objects"
      ]

      inference_api_key = ApiKey.create_inference_api_key(project)
      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: ActionTag[project_id: nil, name: "Member"].id, object_id: inference_api_key.id)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "Member", inference_api_key.ubid,
        "Tname", "Member", "OTest2",
        "Tname", "Project:view", "All Objects",
        "Tname", "ATest", "All Objects",
        "Tname", "ATest", "OTest1",
        "Tname", "ATest", "OTest2",
        "Tname", "ATest", "OTest2",
        "STest", "All Actions", "All Objects"
      ]

      AccessControlEntry.create_with_id(project_id:, subject_id: user.id, action_id: at.id, object_id: ot1.metatag_uuid)
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Tname", "Member", inference_api_key.ubid,
        "Tname", "Member", "OTest2",
        "Tname", "Project:view", "All Objects",
        "Tname", "ATest", "All Objects",
        "Tname", "ATest", "OTest1",
        "Tname", "ATest", "OTest1",
        "Tname", "ATest", "OTest2",
        "Tname", "ATest", "OTest2",
        "STest", "All Actions", "All Objects"
      ]

      project.subject_tags_dataset.where(name: "Admin").first.remove_members([user.id])
      ace.destroy
      AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Account: Tname", "Global Tag: Member", "InferenceApiKey: #{inference_api_key.ubid}",
        "Account: Tname", "Global Tag: Member", "Tag: OTest2",
        "Account: Tname", "Project:view", "All",
        "Account: Tname", "Project:viewaccess", "All",
        "Account: Tname", "Tag: ATest", "All",
        "Account: Tname", "Tag: ATest", "ObjectTag: OTest1",
        "Account: Tname", "Tag: ATest", "Tag: OTest1",
        "Account: Tname", "Tag: ATest", "Tag: OTest2",
        "Account: Tname", "Tag: ATest", "Tag: OTest2",
        "Tag: STest", "All", "All"
      ]
    end

    it "requires Project:viewaccess permissions to view access control entries" do
      project
      user.update(name: "foo")
      AccessControlEntry.dataset.destroy
      visit "#{project.path}/user/access-control"
      expect(page.status_code).to eq 403

      AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
      page.refresh
      expect(page.title).to eq "Ubicloud - Default - Access Control"
      expect(displayed_access_control_entries).to eq [
        "Account: foo", "Project:viewaccess", "All"
      ]
      expect(page).to have_no_content("Save All")
      expect(page).to have_no_content("New Access Control Entry")

      AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:editaccess"])
      page.refresh
      expect(displayed_access_control_entries).to eq [
        "foo", "Project:editaccess", "All Objects",
        "foo", "Project:viewaccess", "All Objects"
      ]
      expect(page).to have_content("Save All")
      expect(page).to have_content("New Access Control Entry")
    end

    it "does not show access control entries for tokens" do
      AccessControlEntry.create_with_id(project_id: project.id, subject_id: ApiKey.create_personal_access_token(user, project:).id)

      visit "#{project.path}/user/access-control"
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Member", "Member", "All Objects"
      ]
    end

    it "can create access control entries" do
      user.update(name: "Tname")
      project_id = project.id
      SubjectTag.create_with_id(project_id:, name: "STest")
      ActionTag.create_with_id(project_id:, name: "ATest")
      ObjectTag.create_with_id(project_id:, name: "OTest")

      visit "#{project.path}/user/access-control"
      within("#ace-template .subject") { select "Tname" }
      click_button "Save All"
      expect(find_by_id("flash-notice").text).to include("Access control entries saved successfully")
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Member", "Member", "All Objects"
      ]

      within("#ace-template .subject") { select "STest" }
      within("#ace-template .action") { select "ATest" }
      within("#ace-template .object #object-tag-group") { select "OTest" }
      click_button "Save All"
      expect(find_by_id("flash-notice").text).to include("Access control entries saved successfully")
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Member", "Member", "All Objects",
        "STest", "ATest", "OTest"
      ]

      within("#ace-template .subject") { select "STest" }
      within("#ace-template .action") { select "Member" }
      click_button "Save All"
      expect(find_by_id("flash-notice").text).to include("Access control entries saved successfully")
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Member", "Member", "All Objects",
        "STest", "Member", "All Objects",
        "STest", "ATest", "OTest"
      ]

      within("#ace-template .subject") { select "STest" }
      within("#ace-template .action") { select "Member" }
      within("#ace-template") { check "Delete" }
      click_button "Save All"
      expect(find_by_id("flash-notice").text).to include("Access control entries saved successfully")
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "All Objects",
        "Member", "Member", "All Objects",
        "STest", "Member", "All Objects",
        "STest", "ATest", "OTest"
      ]
    end

    it "can update access control entries" do
      ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id)
      SubjectTag.create_with_id(project_id: project.id, name: "STest")
      visit "#{project.path}/user/access-control"
      within("#ace-#{ace.ubid} .subject") { select "STest" }
      click_button "Save All"
      expect(find_by_id("flash-notice").text).to include("Access control entries saved successfully")
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Member", "Member", "All Objects",
        "STest", "All Actions", "All Objects"
      ]
    end

    it "skips nonexisting entries when updating access control entries" do
      ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id)
      SubjectTag.create_with_id(project_id: project.id, name: "STest")
      visit "#{project.path}/user/access-control"
      within("#ace-#{ace.ubid} .subject") { select "STest" }
      ace.destroy
      click_button "Save All"
      expect(find_by_id("flash-notice").text).to include("Access control entries saved successfully")
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Member", "Member", "All Objects"
      ]
    end

    it "can delete access control entries" do
      ace = AccessControlEntry[project_id: project.id, action_id: Sequel::NOTNULL]
      visit "#{project.path}/user/access-control"
      within("#ace-#{ace.ubid}") { check "Delete" }
      click_button "Save All"
      expect(find_by_id("flash-notice").text).to include("Access control entries saved successfully")
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All"
      ]
    end

    it "requires Project:editaccess permissions to create access control entries" do
      user.update(name: "Tname")
      project
      AccessControlEntry.dataset.destroy
      visit "#{project.path}/user/access-control"
      expect(page.status_code).to eq 403

      ace1 = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
      ace2 = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:editaccess"])
      page.refresh
      expect(page.title).to eq "Ubicloud - Default - Access Control"

      within("#ace-template .subject") { select "Tname" }
      ace2.destroy
      click_button "Save All"
      expect(page.status_code).to eq 403
      expect(AccessControlEntry.all).to eq [ace1]
    end

    it "requires Project:editaccess permissions to update access control entries" do
      user.update(name: "Tname")
      project
      AccessControlEntry.dataset.destroy
      ace1 = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
      ace2 = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:editaccess"])
      visit "#{project.path}/user/access-control"

      within("#ace-#{ace1.ubid} .action") { select "Member" }
      ace2.destroy
      click_button "Save All"
      expect(page.status_code).to eq 403
      expect(AccessControlEntry.all).to eq [ace1]
    end

    it "requires Project:editaccess permissions to delete access control entries" do
      user.update(name: "Tname")
      project
      AccessControlEntry.dataset.destroy
      ace1 = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
      ace2 = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:editaccess"])
      visit "#{project.path}/user/access-control"
      within("#ace-#{ace1.ubid}") { check "Delete" }
      ace2.destroy
      click_button "Save All"
      expect(page.status_code).to eq 403
      expect(AccessControlEntry.all).to eq [ace1]
    end

    it "cannot create access control entries for tokens" do
      # Create subject tag with the same id as token to avoid need to muck with the UI
      SubjectTag.create(project_id: project.id, name: "STest") { |st| st.id = ApiKey.create_personal_access_token(user, project:).id }
      visit "#{project.path}/user/access-control"
      within("#ace-template .subject") { select "STest" }
      expect(AccessControlEntry.count).to eq 2
      click_button "Save All"
      expect(AccessControlEntry.count).to eq 2
    end

    it "cannot create access control entries for the Admin subject Tag" do
      SubjectTag.where(project_id: project.id, name: "Admin").update(name: "Temp")
      visit "#{project.path}/user/access-control"
      within("#ace-template .subject") { select "Temp" }
      SubjectTag.where(project_id: project.id, name: "Temp").update(name: "Admin")
      expect(AccessControlEntry.count).to eq 2
      click_button "Save All"
      expect(AccessControlEntry.count).to eq 2
    end

    %w[subject action object].each do |type|
      cap_type = type.capitalize
      model = Object.const_get(:"#{cap_type}Tag")
      perm_type = "Project:#{cap_type.sub(/(ect|ion)\z/, "").downcase}tag"

      it "can view #{type} tags" do
        visit "#{project.path}/user/access-control"
        find("##{cap_type.downcase}-tags-link").click
        expect(page.title).to eq "Ubicloud - Default - #{cap_type} Tags"
        tds = page.all("table#tag-list td").map(&:text)

        if type == "subject"
          expect(tds).to eq [
            "Admin", "Manage",
            "Member", "Manage Remove"
          ]
        else
          expect(tds).to eq []
        end

        model.create_with_id(project_id: project.id, name: "test-#{type}")
        page.refresh
        tds = page.all("table#tag-list td").map(&:text)

        if type == "subject"
          expect(tds).to eq [
            "Admin", "Manage",
            "Member", "Manage Remove",
            "test-subject", "Manage Remove"
          ]
        else
          expect(tds).to eq ["test-#{type}", "Manage Remove"]
        end
      end

      it "requires Project:viewaccess permissions to view #{type} tags, #{perm_type} to see create/remove links, and only display tags with #{cap_type}Tag:view permissions" do
        project
        AccessControlEntry.dataset.destroy
        visit "#{project.path}/user/access-control/tag/#{type}"
        expect(page.status_code).to eq 403

        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
        page.refresh
        expect(page.title).to eq "Ubicloud - Default - #{cap_type} Tags"
        expect(page).to have_content("No managable #{type} tags to display")

        tag = model.create_with_id(project_id: project.id, name: "test-#{type}1")
        model.create_with_id(project_id: project.id, name: "test-#{type}2")

        if type == "object"
          # Access to object tag does not imply ability to manage tag, only members of tag
          # Must grant access to metatag to manage tag itself
          AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:view"], object_id: tag.id)
          page.refresh
          expect(page).to have_content("No managable object tags to display")
        end

        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:view"], object_id: (type == "object") ? tag.metatag_uuid : tag.id)
        page.refresh
        expect(page).to have_no_content("Create #{cap_type} Tag")
        expect(page.all("table#tag-list td").map(&:text)).to eq [
          "test-#{type}1", "Manage"
        ]
        expect(page.all("table#tag-list td a").map(&:text)).to eq [
          "Manage"
        ]

        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP[perm_type])
        page.refresh
        expect(page).to have_content("Create #{cap_type} Tag")
        expect(page.all("table#tag-list td").map(&:text)).to eq [
          "test-#{type}1", "Manage Remove"
        ]
        expect(page.all("table#tag-list td a").map(&:text)).to eq [
          "Manage"
        ]

        click_link "Manage"
        expect(page.title).to eq "Ubicloud - Default - #{tag.name}"
      end

      it "can create #{type} tag" do
        visit "#{project.path}/user/access-control/tag/#{type}"
        fill_in "Name", with: "-"
        click_button "Create"
        expect(page).to have_flash_error "name must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number"

        name = "test-#{type}"
        fill_in "Name", with: name
        click_button "Create"
        expect(model[project_id: project.id, name:]).not_to be_nil
        expect(page).to have_flash_notice "#{cap_type} tag created successfully"
        expect(page.title).to eq "Ubicloud - Default - #{cap_type} Tags"
        expect(page.html).to include name
      end

      it "requires #{perm_type} permissions to create #{type} tag" do
        project
        AccessControlEntry.dataset.destroy
        visit "#{project.path}/user/access-control/tag/#{type}"
        expect(page.status_code).to eq 403

        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
        page.refresh
        expect(page.title).to eq "Ubicloud - Default - #{cap_type} Tags"
        expect(page).to have_no_content("Create #{cap_type} Tag")

        ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP[perm_type])
        page.refresh
        expect(page).to have_content("Create #{cap_type} Tag")

        ace.destroy
        name = "test-#{type}"
        fill_in "Name", with: name
        click_button "Create"
        expect(page.status_code).to eq 403
        expect(model.where(name:).all).to be_empty
      end

      it "can rename #{type} tag" do
        name = "test-#{type}"
        ubid = model.create_with_id(project_id: project.id, name:).ubid
        visit "#{project.path}/user/access-control/tag/#{type}"
        click_link "#{ubid}-edit"

        expect(page.title).to eq "Ubicloud - Default - #{name}"
        fill_in "Name", with: "-"
        click_button "Update"
        expect(page).to have_flash_error "name must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number"

        old_name = name
        name = "test2-#{type}"
        fill_in "Name", with: name
        click_button "Update"
        expect(model[project_id: project.id, name: old_name]).to be_nil
        expect(model[project_id: project.id, name:]).not_to be_nil
        expect(page).to have_flash_notice "#{cap_type} tag name updated successfully"
        expect(page.title).to eq "Ubicloud - Default - #{name}"
        expect(page.html).to include name
        expect(page.html).not_to include old_name
      end

      it "requires #{perm_type} permissions to rename #{type} tag" do
        project
        AccessControlEntry.dataset.destroy
        name = "test-#{type}"
        tag = model.create_with_id(project_id: project.id, name:)
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag.ubid}"
        expect(page.status_code).to eq 403

        ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP[perm_type])
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:view"], object_id: (type == "object") ? tag.metatag_uuid : tag.id)

        page.refresh
        expect(page.title).to eq "Ubicloud - Default - #{name}"

        ace.destroy
        name = "test2-#{type}"
        fill_in "Name", with: name
        click_button "Update"
        expect(page.status_code).to eq 403
        expect(model.where(name:).all).to be_empty
      end

      it "can delete #{type} tag" do
        SubjectTag.where(name: "Member").destroy
        name = "test-#{type}"
        model.create_with_id(project_id: project.id, name:)
        visit "#{project.path}/user/access-control/tag/#{type}"

        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(model[project_id: project.id, name:]).to be_nil

        visit "#{project.path}/user/access-control/tag/#{type}"
        expect(page).to have_flash_notice "#{cap_type} tag deleted successfully"
      end

      it "requires #{perm_type} permissions to delete #{type} tag" do
        project
        AccessControlEntry.dataset.destroy
        name = "test-#{type}"
        tag = model.create_with_id(project_id: project.id, name:)
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:viewaccess"])
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:view"], object_id: (type == "object") ? tag.metatag_uuid : tag.id)
        ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP[perm_type])
        visit "#{project.path}/user/access-control/tag/#{type}"

        ace.destroy
        btn = find ".delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(page.status_code).to eq 403
        expect(tag.exists?).to be true
      end

      it "shows not found page for invalid #{type} tag ubid" do
        visit "#{project.path}/user/access-control/tag/#{type}/#{model.generate_uuid}"
        expect(page.status_code).to eq 404
      end

      it "can view members of #{type} tag" do
        Account.first.update(name: "test-account") if type == "subject"
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        visit "#{project.path}/user/access-control/tag/#{type}"
        page.find("##{tag1.ubid}-edit").click

        expect(page.title).to eq "Ubicloud - Default - #{tag1.name}"
        expect(page.html).not_to include "Current Members of #{cap_type} Tag"
        global_tags = ActionTag.where(project_id: nil).select_order_map(:name)
        action_types = ActionType.map(&:name).sort
        default = lambda do
          case type
          when "subject"
            expect(page.all("table#tag-membership-add tbody th").map(&:text)).to eq ["Tag", "Account"]
            expect(page.all("table#tag-membership-add td").map(&:text)).to eq ["Member", "", "test-account", ""]
          when "action"
            expect(page.all("table#tag-membership-add tbody th").map(&:text)).to eq ["Global Tag", "Action"]
            expect(page.all("table#tag-membership-add td").map(&:text)).to eq (global_tags + action_types).flat_map { [it, ""] }
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
          expect(page.all("table#tag-membership-add tbody th").map(&:text)).to eq ["Tag", "Account"]
          expect(page.all("table#tag-membership-add td").map(&:text)).to eq ["Member", "", "other-subject", "", "test-account", ""]
        when "action"
          expect(page.all("table#tag-membership-add tbody th").map(&:text)).to eq ["Global Tag", "Tag", "Action"]
          expect(page.all("table#tag-membership-add td").map(&:text)).to eq [*global_tags, "other-action", *action_types].flat_map { [it, ""] }
        else
          expect(page.all("table#tag-membership-add tbody th").map(&:text)).to eq ["Tag (grants access to objects contained in tag)", "Project", "SubjectTag", "ObjectTag (grants access to tag itself)"]
          expect(page.all("table#tag-membership-add td").map(&:text)).to eq ["other-object", "", "Default", "", "Admin", "", "Member", "", "other-object", "", "test-object", ""]
        end

        tag1.add_member(tag2.id)
        page.refresh
        expect(page.html).to match(/Current\s*Members/)
        expect(page.all("table#tag-membership-remove td").map(&:text)).to eq ["Tag: other-#{type}", ""]
        default.call
      end

      it "requires #{model}:view permissions to view members of #{type} tag, and #{model}:{add,remove} to show options" do
        project
        SubjectTag.where(name: "Member").destroy
        AccessControlEntry.dataset.destroy
        name = "test-#{type}"
        tag = model.create_with_id(project_id: project.id, name:)
        tag2 = model.create_with_id(project_id: project.id, name: "test2-#{type}")
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag.ubid}"
        expect(page.status_code).to eq 403

        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:view"], object_id: (type == "object") ? tag.metatag_uuid : tag.id)
        page.refresh
        expect(page.title).to eq "Ubicloud - Default - #{name}"
        expect(page.html).to match(/No current members of\s+#{type}\s+tag\./m)
        expect(page.all("table#tag-membership-add td").map(&:text)).to be_empty
        expect(page.html).not_to include("Add Members")
        expect(page.html).not_to include("Remove Members")

        tag.add_member(tag2.id)
        page.refresh
        expect(page.all("table#tag-membership-remove td").map(&:text)).to eq ["Tag: test2-#{type}"]
        expect(page.all("table#tag-membership-add td").map(&:text)).to be_empty
        expect(page.html).not_to include("Add Members")
        expect(page.html).not_to include("Remove Members")

        ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:remove"], object_id: (type == "object") ? tag.metatag_uuid : tag.id)
        page.refresh
        expect(page.all("table#tag-membership-remove td").map(&:text)).to eq ["Tag: test2-#{type}", ""]
        expect(page.all("table#tag-membership-add td").map(&:text)).to be_empty
        expect(page.html).not_to include("Add Members")
        expect(page.html).to include("Remove Members")

        ace.update(action_id: ActionType::NAME_MAP["#{cap_type}Tag:add"])
        model.create_with_id(project_id: project.id, name: "test3-#{type}")
        page.refresh
        expect(page.all("table#tag-membership-remove td").map(&:text)).to eq ["Tag: test2-#{type}"]
        tds = page.all("table#tag-membership-add td, table#tag-membership-add tbody th").map(&:text)
        expected = case type
        when "subject"
          ["Tag",
            "test3-subject", "",
            "Account",
            "", ""]
        when "action"
          ["Global Tag",
            *ActionTag.where(project_id: nil).select_order_map(:name).flat_map { [it, ""] },
            "Tag",
            "test3-action", "",
            "Action",
            *ActionType.map(&:name).sort.flat_map { [it, ""] }]
        else
          ["Tag (grants access to objects contained in tag)",
            "test3-object", "",
            "Project",
            "Default", "",
            "SubjectTag",
            "Admin", "",
            "ObjectTag (grants access to tag itself)",
            "test-object", "",
            "test2-object", "",
            "test3-object", ""]
        end
        expect(tds).to eq expected
        expect(page.html).to include("Add Members")
        expect(page.html).not_to include("Remove Members")
      end

      it "can add members to #{type} tag" do
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}"

        find("##{tag2.ubid} input").check
        click_button "Add Members"
        expect(tag1.member_ids).to include tag2.id
        expect(page.title).to eq "Ubicloud - Default - #{tag1.name}"
        expect(page).to have_flash_notice "1 members added to #{type} tag"
      end

      it "handles errors when adding members to #{type} tag" do
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}"

        tag1.add_member(tag2.id)
        find("##{tag2.ubid} input").check
        click_button "Add Members"
        expect(tag1.member_ids).to include tag2.id
        expect(page.title).to eq "Ubicloud - Default - #{tag1.name}"
        expect(page).to have_flash_error "No change in membership: 1 members already in tag"
      end

      it "requires #{model}:add permissions to add members to #{type} tag" do
        project
        AccessControlEntry.dataset.destroy
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:view"], object_id: (type == "object") ? tag1.metatag_uuid : tag1.id)
        ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:add"], object_id: (type == "object") ? tag1.metatag_uuid : tag1.id)
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}"

        ace.destroy
        find("##{tag2.ubid} input").check
        click_button "Add Members"
        expect(page.status_code).to eq 403
        expect(tag1.member_ids).to be_empty
      end

      it "can remove members from #{type} tag" do
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        tag1.add_member(tag2.id)
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}"

        find("##{tag2.ubid} input").check
        click_button "Remove Members"
        expect(tag1.member_ids).to be_empty
        expect(page.title).to eq "Ubicloud - Default - #{tag1.name}"
        expect(page).to have_flash_notice "1 members removed from #{type} tag"
      end

      it "requires #{model}:remove permissions to remove members from #{type} tag" do
        project
        AccessControlEntry.dataset.destroy
        tag1 = model.create_with_id(project_id: project.id, name: "test-#{type}")
        tag2 = model.create_with_id(project_id: project.id, name: "other-#{type}")
        tag1.add_member(tag2.id)
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:view"], object_id: (type == "object") ? tag1.metatag_uuid : tag1.id)
        ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["#{cap_type}Tag:remove"], object_id: (type == "object") ? tag1.metatag_uuid : tag1.id)
        visit "#{project.path}/user/access-control/tag/#{type}/#{tag1.ubid}"

        ace.destroy
        find("##{tag2.ubid} input").check
        click_button "Remove Members"
        expect(page.status_code).to eq 403
        expect(tag1.member_ids).to eq [tag2.id]
      end
    end

    it "can add global action tag members to action tag" do
      tag = ActionTag.create_with_id(project_id: project.id, name: "test-action")
      visit "#{project.path}/user/access-control/tag/action/#{tag.ubid}"

      member_global_tag = ActionTag[project_id: nil, name: "Member"]
      find("##{member_global_tag.ubid} input").check
      click_button "Add Members"
      expect(tag.member_ids).to include member_global_tag.id
      expect(page.title).to eq "Ubicloud - Default - test-action"
      expect(page).to have_flash_notice "1 members added to action tag"
    end

    it "does not show ApiKeys on subject tag membership page" do
      tag = SubjectTag.create_with_id(project_id: project.id, name: "test-subject")
      api_key = ApiKey.create_personal_access_token(user, project: project)
      tag.add_member(api_key.id)
      visit "#{project.path}/user/access-control/tag/subject/#{tag.ubid}"
      expect(page.html).not_to include "Current Members of Subject Tag"
    end

    it "cannot delete Admin subject tag" do
      SubjectTag.where(name: "Member").destroy
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      admin.update(name: "not-Admin")
      visit "#{project.path}/user/access-control/tag/subject"

      admin.update(name: "Admin")
      btn = find ".delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
      expect(SubjectTag[project_id: project.id, name: "Admin"]).not_to be_nil

      visit "#{project.path}/user/access-control/tag/subject"
      expect(page).to have_flash_error "Cannot modify Admin subject tag"
    end

    it "cannot rename Admin subject tag" do
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      visit "#{project.path}/user/access-control/tag/subject/#{admin.ubid}"

      expect(page).to have_no_content("Update Subject Tag")

      admin.update(name: "not-Admin")
      visit "#{project.path}/user/access-control/tag/subject/#{admin.ubid}"
      admin.update(name: "Admin")
      expect(page).to have_content("Update Subject Tag")
      fill_in "Name", with: "not-Admin"
      click_button "Update"
      expect(page).to have_flash_error "Cannot modify Admin subject tag"
    end

    it "cannot add Admin subject tag to another subject tag" do
      tag = SubjectTag.create_with_id(project_id: project.id, name: "test-subject")
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      admin.update(name: "not-Admin")
      visit "#{project.path}/user/access-control/tag/subject/#{tag.ubid}"
      admin.update(name: "Admin")
      find("##{admin.ubid} input").check
      click_button "Add Members"
      expect(page).to have_flash_error "No change in membership: cannot include Admin subject tag in another tag, 1 members not valid"
    end

    it "supports adding InferenceApiKey to ObjectTag" do
      inference_api_key = ApiKey.create_inference_api_key(project)
      tag = ObjectTag.create_with_id(project_id: project.id, name: "test-obj")
      visit "#{project.path}/user/access-control/tag/object/#{tag.ubid}"
      find("##{inference_api_key.ubid} input").check
      click_button "Add Members"
      expect(page).to have_flash_notice "1 members added to object tag"
      expect(page.all("table#tag-membership-remove td").map(&:text)).to eq [
        "InferenceApiKey: #{inference_api_key.ubid}", ""
      ]
    end

    it "supports adding ObjectTag to ObjectTag, both as regular tag and metatag" do
      tag1 = ObjectTag.create_with_id(project_id: project.id, name: "test-obj")
      tag2 = ObjectTag.create_with_id(project_id: project.id, name: "other-obj")
      visit "#{project.path}/user/access-control/tag/object/#{tag1.ubid}"
      find("##{tag1.metatag_ubid} input").check
      find("##{tag2.ubid} input").check
      find("##{tag2.metatag_ubid} input").check
      click_button "Add Members"
      expect(page).to have_flash_notice "3 members added to object tag"
      expect(page.all("table#tag-membership-remove td").map(&:text)).to eq [
        "ObjectTag: other-obj", "",
        "ObjectTag: test-obj", "",
        "Tag: other-obj", ""
      ]
    end

    it "supports display of SubjectTag/ActionTag in ObjectTag membership page" do
      st = SubjectTag.create_with_id(project_id: project.id, name: "st")
      at = ActionTag.create_with_id(project_id: project.id, name: "at")
      tag = ObjectTag.create_with_id(project_id: project.id, name: "test-obj")
      visit "#{project.path}/user/access-control/tag/object/#{tag.ubid}"
      find("##{st.ubid} input").check
      find("##{at.ubid} input").check
      click_button "Add Members"
      expect(page).to have_flash_notice "2 members added to object tag"
      expect(page.all("table#tag-membership-remove td").map(&:text)).to eq [
        "ActionTag: at", "",
        "SubjectTag: st", ""
      ]
    end

    it "shows object metatag with ObjectTag prefix when viewing access control entries" do
      user.update(name: "Tname")
      tag = ObjectTag.create_with_id(project_id: project.id, name: "test-obj")
      AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, object_id: tag.metatag_uuid)
      visit "#{project.path}/user/access-control"
      expect(displayed_access_control_entries).to eq [
        "Tag: Admin", "All", "All",
        "Tname", "All Actions", "test-obj",
        "Member", "Member", "All Objects"
      ]
    end

    it "cannot remove all accounts from Admin subject tag" do
      admin = SubjectTag[project_id: project.id, name: "Admin"]
      visit "#{project.path}/user/access-control/tag/subject/#{admin.ubid}"
      check "remove[]"
      2.times do
        click_button "Remove Members"
        expect(page).to have_flash_error "Must keep at least one account in Admin subject tag"
        expect(page.title).to eq "Ubicloud - Default - Admin"
      end
    end

    it "handles serialization failure when adding members" do
      tag1 = SubjectTag.create_with_id(project_id: project.id, name: "test-subject")
      tag2 = SubjectTag.create_with_id(project_id: project.id, name: "other-subject")
      visit "#{project.path}/user/access-control/tag/subject/#{tag1.ubid}"

      find("##{tag2.ubid} input").check
      5.times do
        expect(UBID).to receive(:class_match?).and_raise(Sequel::SerializationFailure)
        click_button "Add Members"
        expect(page).to have_flash_error "There was a temporary error attempting to make this change, please try again."
      end

      expect(UBID).to receive(:class_match?).and_return(false)
      click_button "Add Members"
      expect(tag1.member_ids).to include tag2.id
      expect(page.title).to eq "Ubicloud - Default - #{tag1.name}"
      expect(page).to have_flash_notice "1 members added to subject tag"
    end
  end
end
