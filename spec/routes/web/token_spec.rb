# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "personal access token management" do
  let(:user) { create_account }

  let(:project) { user.projects.first }

  # Show the displayed access control entries, except for the Admin one
  def displayed_access_control_entries
    page.all("table#access-control-entries .existing-aces-view td.values").map(&:text) +
      page.all("table#access-control-entries .existing-aces select")
        .map { |select| select.all("option[selected]")[0] || select.first("option") }
        .map(&:text)
  end

  before do
    login(user.email)
    visit "#{project.path}/token"
    expect(ApiKey.all).to be_empty
    click_button "Create Token"
    @api_key = ApiKey.first
  end

  it "is directly accessible from dashboard" do
    AccessControlEntry.dataset.destroy
    visit "#{project.path}/dashboard"
    expect(find_by_id("desktop-menu").text).not_to include("Tokens")

    AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:token"])
    visit "#{project.path}/dashboard"

    page.within("#desktop-menu") do
      click_link "Tokens"
    end
    expect(page.title).to eq "Ubicloud - Default - Personal Access Tokens"
  end

  it "requires Project:token permission to access token page and create/remove tokens" do
    AccessControlEntry.dataset.destroy
    page.refresh
    expect(page.status_code).to eq 403

    AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:user"])
    page.refresh
    expect(page.status_code).to eq 403

    ace = AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:token"])
    page.refresh
    expect(page.title).to eq "Ubicloud - Default - Personal Access Tokens"

    click_button "Remove"
    expect(page).to have_flash_notice("Personal access token deleted successfully")
    expect(ApiKey.count).to eq 0

    click_button "Create Token"
    expect(ApiKey.count).to eq 1

    ace.destroy
    click_button "Create Token"
    expect(page.status_code).to eq 403
    expect(ApiKey.count).to eq 1

    ace = AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:token"])
    visit "#{project.path}/token"
    ace.destroy
    click_button "Remove"
    expect(ApiKey.count).to eq 1
  end

  it "user page allows creating personal access tokens" do
    expect(page).to have_flash_notice("Created personal access token with id #{@api_key.ubid}")

    expect(ApiKey.count).to eq(1)
    expect(@api_key.owner_id).to eq(user.id)
    expect(@api_key.owner_table).to eq("accounts")
    expect(@api_key.project).to eq(project)
    expect(@api_key.used_for).to eq("api")
    expect(@api_key.is_valid).to be(true)
    expect(SubjectTag[project_id: project.id, name: "Admin"].member_ids).to include @api_key.id
  end

  it "user page only shows tokens related to project" do
    key = ApiKey.create_personal_access_token(user, project: Project.create(name: "test2"))
    page.refresh
    expect(page).to have_content(@api_key.ubid)
    expect(page).to have_no_content(key.ubid)
  end

  it "user page allows removing personal access tokens" do
    AccessControlEntry.create(project_id: project.id, subject_id: @api_key.id)

    click_button "Remove"
    expect(page).to have_flash_notice("Personal access token deleted successfully")
    expect(ApiKey.all).to be_empty
    expect(DB[:applied_subject_tag].where(tag_id: project.subject_tags_dataset.first(name: "Admin").id, subject_id: @api_key.id).all).to be_empty
    expect(AccessControlEntry.where(project_id: project.id, subject_id: @api_key.id).all).to be_empty

    page.refresh
    expect(page.html).not_to include("Personal access token deleted successfully")
  end

  it "can restrict access" do
    click_link @api_key.ubid
    expect(page.title).to eq "Ubicloud - Default - Token #{@api_key.ubid}"
    expect(@api_key.unrestricted_token_for_project?(project.id)).to be true
    click_button "Restrict Token Access"

    expect(find_by_id("flash-notice").text).to eq "Restricted personal access token"
    expect(@api_key.unrestricted_token_for_project?(project.id)).to be false
    expect(page.title).to eq "Ubicloud - Default - Token #{@api_key.ubid}"
  end

  it "cannot view token access control entries for token not associated with this project" do
    key = ApiKey.create_personal_access_token(user, project: Project.create(name: "test2"))
    visit "#{project.path}/token/#{key.ubid}/access-control"
    expect(page.status_code).to eq 404
  end

  it "can view token access control entries" do
    @api_key.restrict_token_for_project(project.id)
    click_link @api_key.ubid
    expect(page.title).to eq "Ubicloud - Default - Token #{@api_key.ubid}"
    expect(page).to have_content "Currently, this token has no access to the project."

    AccessControlEntry.create(project_id: project.id, subject_id: @api_key.id)
    page.refresh
    expect(displayed_access_control_entries).to eq [
      "All Actions", "All Objects",
    ]
  end

  it "can create token access control entries" do
    @api_key.restrict_token_for_project(project.id)
    click_link @api_key.ubid
    within("#ace-template .action") { select "ActionTag:add" }
    expect(displayed_access_control_entries).to eq []

    ObjectTag.create(project_id: project.id, name: "OTest")
    click_button "Save All"
    expect(find_by_id("flash-notice").text).to eq "Token access control entries saved successfully"
    expect(displayed_access_control_entries).to eq [
      "ActionTag:add", "All Objects",
    ]

    within("#ace-template .action") { select "ActionTag:view" }
    within("#ace-template .object #object-tag-group") { select "OTest" }
    click_button "Save All"
    expect(displayed_access_control_entries).to eq [
      "ActionTag:add", "All Objects",
      "ActionTag:view", "OTest",
    ]

    within("#ace-template .action") { select "SubjectTag:view" }
    within("#ace-template .object #object-tag-group") { select "OTest" }
    within("#ace-template") { check "Delete" }
    click_button "Save All"
    expect(displayed_access_control_entries).to eq [
      "ActionTag:add", "All Objects",
      "ActionTag:view", "OTest",
    ]
  end

  it "can edit token access control entries" do
    @api_key.restrict_token_for_project(project.id)
    ace = AccessControlEntry.create(project_id: project.id, subject_id: @api_key.id)
    ObjectTag.create(project_id: project.id, name: "OTest")
    click_link @api_key.ubid
    expect(page.title).to eq "Ubicloud - Default - Token #{@api_key.ubid}"
    within("#ace-#{ace.ubid} .action") { select "ActionTag:view" }
    within("#ace-#{ace.ubid} .object #object-tag-group") { select "OTest" }
    click_button "Save All"
    expect(find_by_id("flash-notice").text).to eq "Token access control entries saved successfully"
    expect(displayed_access_control_entries).to eq [
      "ActionTag:view", "OTest",
    ]
  end

  it "ignores unmatched entries when editing access control entries" do
    @api_key.restrict_token_for_project(project.id)
    ace = AccessControlEntry.create(project_id: project.id, subject_id: @api_key.id)
    ObjectTag.create(project_id: project.id, name: "OTest")
    click_link @api_key.ubid
    expect(page.title).to eq "Ubicloud - Default - Token #{@api_key.ubid}"
    within("#ace-#{ace.ubid} .action") { select "ActionTag:view" }
    within("#ace-#{ace.ubid} .object #object-tag-group") { select "OTest" }
    ace.destroy
    click_button "Save All"
    expect(find_by_id("flash-notice").text).to eq "Token access control entries saved successfully"
    expect(displayed_access_control_entries).to eq []
    expect(ace).not_to be_exists
  end

  it "can delete token access control entries" do
    @api_key.restrict_token_for_project(project.id)
    ace = AccessControlEntry.create(project_id: project.id, subject_id: @api_key.id)
    ObjectTag.create(project_id: project.id, name: "OTest")
    click_link @api_key.ubid
    within("#ace-#{ace.ubid}") { check "Delete" }

    click_button "Save All"
    expect(find_by_id("flash-notice").text).to eq "Token access control entries saved successfully"
    expect(ace).not_to be_exists

    expect(page).to have_content "Currently, this token has no access to the project."
  end

  it "can unrestrict tokens after restricting them" do
    @api_key.restrict_token_for_project(project.id)
    ace = AccessControlEntry.create(project_id: project.id, subject_id: @api_key.id)
    click_link @api_key.ubid
    click_button "Unrestrict Token Access"
    expect(find_by_id("flash-notice").text).to eq "Token access is now unrestricted"
    expect(ace).not_to be_exists
    expect(page.title).to eq "Ubicloud - Default - Token #{@api_key.ubid}"
  end

  it "can create a trusted JWT issuer" do
    visit "#{project.path}/token"
    fill_in "name", with: "test-issuer"
    fill_in "issuer", with: "https://auth.example.com"
    fill_in "jwks_uri", with: "https://auth.example.com/.well-known/jwks.json"
    fill_in "audience", with: "ubicloud"
    click_button "Add Trusted Issuer"

    expect(find_by_id("flash-notice").text).to eq "Trusted JWT issuer created"
    expect(TrustedJwtIssuer.count).to eq(1)
    ji = TrustedJwtIssuer.first
    expect(ji.name).to eq("test-issuer")
    expect(ji.issuer).to eq("https://auth.example.com")
    expect(ji.audience).to eq("ubicloud")
    expect(ji.account_id).to eq(user.id)
    expect(page).to have_link(ji.ubid, href: "#{project.path}/token/jwt-issuer/#{ji.ubid}/access-control")
  end

  it "can delete a trusted JWT issuer" do
    ji = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: user.id,
      name: "to-delete",
      issuer: "https://delete.example.com",
      jwks_uri: "https://delete.example.com/.well-known/jwks.json",
    )

    visit "#{project.path}/token"
    within("#jwt-issuer-#{ji.ubid}") { click_button "Remove" }

    expect(find_by_id("flash-notice").text).to eq "Trusted JWT issuer deleted"
    expect(TrustedJwtIssuer.count).to eq(0)
  end

  it "can view trusted JWT issuer access control entries" do
    ji = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: user.id,
      name: "test-issuer",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )

    visit "#{project.path}/token"
    click_link ji.ubid

    expect(page.title).to eq "Ubicloud - Default - Trusted JWT Issuer test-issuer"
    expect(page).to have_content "Currently, this trusted JWT issuer has no access to the project."

    AccessControlEntry.create(project_id: project.id, subject_id: ji.id)
    page.refresh
    expect(displayed_access_control_entries).to eq [
      "All Actions", "All Objects",
    ]
  end

  it "can create trusted JWT issuer access control entries" do
    ji = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: user.id,
      name: "test-issuer",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )
    ObjectTag.create(project_id: project.id, name: "OTest")

    visit "#{project.path}/token/jwt-issuer/#{ji.ubid}/access-control"
    within("#ace-template .action") { select "ActionTag:view" }
    within("#ace-template .object #object-tag-group") { select "OTest" }
    click_button "Save All"

    expect(find_by_id("flash-notice").text).to eq "Trusted JWT issuer access control entries saved successfully"
    expect(displayed_access_control_entries).to eq [
      "ActionTag:view", "OTest",
    ]
  end

  it "returns 404 for web GET on bare jwt-issuer endpoints" do
    visit "#{project.path}/token/jwt-issuer"
    expect(page.status_code).to eq(404)

    ji = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: user.id,
      name: "test",
      issuer: "https://test.example.com",
      jwks_uri: "https://test.example.com/.well-known/jwks.json",
    )
    visit "#{project.path}/token/jwt-issuer/#{ji.ubid}"
    expect(page.status_code).to eq(404)
  end
end
