# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "personal access token management" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  before do
    login(user.email)
    visit "#{project.path}/user/token"
    expect(ApiKey.all).to be_empty
    click_button "Create Token"
    @api_key = ApiKey.first
  end

  it "user page allows creating personal access tokens" do
    expect(page).to have_flash_notice("Created personal access token with id #{@api_key.ubid}")

    expect(ApiKey.count).to eq(1)
    expect(@api_key.owner_id).to eq(user.id)
    expect(@api_key.owner_table).to eq("accounts")
    expect(@api_key.projects).to eq([project])
    expect(@api_key.used_for).to eq("api")
    expect(@api_key.is_valid).to be(true)
  end

  it "user page allows removing personal access tokens" do
    access_tag_ds = DB[:access_tag].where(hyper_tag_id: @api_key.id)
    expect(access_tag_ds.all).not_to be_empty

    btn = find("#managed-token .delete-btn")
    data_url = btn["data-url"]
    _csrf = btn["data-csrf"]
    page.driver.delete data_url, {_csrf:}
    expect(page.status_code).to eq(204)
    expect(ApiKey.all).to be_empty
    expect(access_tag_ds.all).to be_empty
    visit "#{project.path}/user/token"
    expect(page).to have_flash_notice("Personal access token deleted successfully")

    page.driver.delete data_url, {_csrf:}
    expect(page.status_code).to eq(204)
    visit "#{project.path}/user/token"
    expect(page.html).not_to include("Personal access token deleted successfully")
  end

  it "user page allows setting policies for personal access tokens" do
    expect(Authorization.has_permission?(@api_key.id, "*", project.id)).to be(false)
    expect(page).to have_no_select("token_policies[#{@api_key.ubid}]", selected: "Admin")
    within "form#managed-token" do
      select "Admin", from: "token_policies[#{@api_key.ubid}]"
      click_button "Update Personal Access Token Policies"
    end
    expect(page).to have_flash_notice("Personal access token policies updated successfully.")
    expect(page).to have_select("token_policies[#{@api_key.ubid}]", selected: "Admin")
    expect(Authorization.has_permission?(@api_key.id, "*", project.id)).to be(true)
  end
end
