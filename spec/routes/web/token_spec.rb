# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "personal access token management" do
  let(:user) { create_account }

  let(:project) { user.projects.first }

  before do
    login(user.email)
    visit "#{project.path}/user/token"
    expect(ApiKey.all).to be_empty
    click_button "Create Token"
    @api_key = ApiKey.first
  end

  it "is directly accessible from dashboard if Project:user and Project:viewaccess are not allowed" do
    AccessControlEntry.dataset.destroy
    AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:token"])
    visit "#{project.path}/dashboard"

    page.within("#desktop-menu") do
      click_link "Tokens"
    end
    expect(page.title).to eq "Ubicloud - Default - Personal Access Tokens"
  end

  it "only shows token link if user has Project:token permissions" do
    AccessControlEntry.dataset.destroy
    visit "#{project.path}/dashboard"
    expect(find_by_id("desktop-menu").text).not_to include("Users")
    expect(find_by_id("desktop-menu").text).not_to include("Tokens")

    AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:user"])
    page.refresh
    expect(page.html).not_to include("Tokens")
    page.within("#desktop-menu") do
      click_link "Users"
    end
    expect(find_by_id("desktop-menu").text).not_to include("Tokens")

    AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:token"])
    page.refresh
    click_link "Personal Access Tokens"
    expect(page.title).to eq "Ubicloud - Default - Personal Access Tokens"
  end

  it "requires Project:token permission to access token page and create/remove tokens" do
    AccessControlEntry.dataset.destroy
    page.refresh
    expect(page.status_code).to eq 403

    AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:user"])
    page.refresh
    expect(page.status_code).to eq 403

    ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:token"])
    page.refresh
    expect(page.title).to eq "Ubicloud - Default - Personal Access Tokens"

    btn = find(".delete-btn")
    page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
    expect(ApiKey.count).to eq 0

    click_button "Create Token"
    expect(ApiKey.count).to eq 1

    ace.destroy
    click_button "Create Token"
    expect(page.status_code).to eq 403
    expect(ApiKey.count).to eq 1

    ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Project:token"])
    visit "#{project.path}/user/token"
    ace.destroy
    btn = find(".delete-btn")
    page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
    expect(ApiKey.count).to eq 1
  end

  it "user page allows creating personal access tokens" do
    expect(find_by_id("flash-notice").text).to include("Created personal access token with id ")

    expect(ApiKey.count).to eq(1)
    expect(@api_key.owner_id).to eq(user.id)
    expect(@api_key.owner_table).to eq("accounts")
    expect(@api_key.projects).to eq([project])
    expect(@api_key.used_for).to eq("api")
    expect(@api_key.is_valid).to be(true)
    expect(SubjectTag[project_id: project.id, name: "Admin"].member_ids).to include @api_key.id
  end

  it "user page allows removing personal access tokens" do
    access_tag_ds = DB[:access_tag].where(hyper_tag_id: @api_key.id)
    expect(access_tag_ds.all).not_to be_empty
    AccessControlEntry.create_with_id(project_id: project.id, subject_id: @api_key.id)

    btn = find(".delete-btn")
    data_url = btn["data-url"]
    _csrf = btn["data-csrf"]
    page.driver.delete data_url, {_csrf:}
    expect(page.status_code).to eq(204)
    expect(ApiKey.all).to be_empty
    expect(access_tag_ds.all).to be_empty
    expect(DB[:applied_subject_tag].where(tag_id: project.subject_tags_dataset.first(name: "Admin").id, subject_id: @api_key.id).all).to be_empty
    expect(AccessControlEntry.where(project_id: project.id, subject_id: @api_key.id).all).to be_empty

    visit "#{project.path}/user/token"
    expect(find_by_id("flash-notice").text).to eq("Personal access token deleted successfully")

    page.driver.delete data_url, {_csrf:}
    expect(page.status_code).to eq(204)
    visit "#{project.path}/user/token"
    expect(page.html).not_to include("Personal access token deleted successfully")
  end
end
