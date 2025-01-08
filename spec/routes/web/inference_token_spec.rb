# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "inference-token" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "feature enabled" do
    before do
      login(user.email)
      visit "#{project.path}/inference-token"
      expect(ApiKey.all).to be_empty
      click_button "Create Token"
      @api_key = ApiKey.first
    end

    it "inference token page allows creating inference tokens" do
      expect(page).to have_flash_notice("Created inference token with id #{@api_key.ubid}")

      expect(ApiKey.count).to eq(1)
      expect(@api_key.owner_id).to eq(project.id)
      expect(@api_key.owner_table).to eq("project")
      expect(@api_key.projects).to eq([project])
      expect(@api_key.used_for).to eq("inference_endpoint")
      expect(@api_key.is_valid).to be(true)
    end

    it "inference token page allows removing inference tokens" do
      access_tag_ds = DB[:access_tag].where(hyper_tag_id: @api_key.id)
      expect(access_tag_ds.all).not_to be_empty

      btn = find(".delete-btn")
      data_url = btn["data-url"]
      _csrf = btn["data-csrf"]
      page.driver.delete data_url, {_csrf:}
      expect(page.status_code).to eq(204)
      expect(ApiKey.all).to be_empty
      expect(access_tag_ds.all).to be_empty
      visit "#{project.path}/user/token"
      expect(page).to have_flash_notice("Inference token deleted successfully")

      page.driver.delete data_url, {_csrf:}
      expect(page.status_code).to eq(204)
      visit "#{project.path}/user/token"
      expect(page.html).not_to include("Inference token deleted successfully")
    end
  end

  describe "unauthenticated" do
    it "inference token page is not accessible" do
      visit "/inference-token"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
