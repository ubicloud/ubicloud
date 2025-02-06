# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "inference-api-key" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "feature enabled" do
    before do
      login(user.email)
      visit "#{project.path}/inference-api-key"
      expect(ApiKey.all).to be_empty
      click_button "Create API Key"
      @api_key = ApiKey.first
    end

    it "inference api key page allows creating inference api key" do
      expect(page).to have_flash_notice("Created Inference API Key with id #{@api_key.ubid}. It may take a few minutes to sync.")

      expect(ApiKey.count).to eq(1)
      expect(@api_key.owner_id).to eq(project.id)
      expect(@api_key.owner_table).to eq("project")
      expect(@api_key.project).to eq(project)
      expect(@api_key.used_for).to eq("inference_endpoint")
      expect(@api_key.is_valid).to be(true)

      expect(page).to have_content "Create API Key"
    end

    it "inference token does not show create or delete options without permissions" do
      AccessControlEntry.dataset.destroy
      AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["InferenceApiKey:view"])

      page.refresh
      expect { find "#api-key-#{@api_key.ubid} .delete-btn" }.to raise_error Capybara::ElementNotFound
      expect(page).to have_no_content "Create API Key"
    end

    it "inference api key page allows removing inference api keys" do
      btn = find(".delete-btn")
      data_url = btn["data-url"]
      _csrf = btn["data-csrf"]
      page.driver.delete data_url, {_csrf:}
      expect(page.status_code).to eq(204)
      expect(ApiKey.all).to be_empty
      visit "#{project.path}/inference-api-key"
      expect(page).to have_flash_notice("Inference API Key deleted successfully")

      page.driver.delete data_url, {_csrf:}
      expect(page.status_code).to eq(204)
      visit "#{project.path}/inference-api-key"
      expect(page.html).not_to include("Inference API Key deleted successfully")
    end
  end

  describe "unauthenticated" do
    it "inference api key page is not accessible" do
      visit "/inference-api-key"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
