# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "detachable volume" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "unauthenticated" do
    it "requires login for list" do
      visit "#{project.path}/detachable-volume"
      expect(page.title).to eq("Ubicloud - Login")
    end

    it "requires login for create" do
      visit "#{project.path}/detachable-volume/create"
      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before { login(user.email) }

    it "can create and view storage volume" do
      visit "#{project.path}/detachable-volume"
      expect(page).to have_content "No storage volumes"
      click_link "Create Storage Volume"
      expect(page.title).to eq("Ubicloud - Create Storage Volume")
      fill_in "Name", with: "vol1"
      choose option: "10"
      click_button "Create"
      expect(page.title).to eq("Ubicloud - vol1")
      expect(DetachableVolume.count).to eq(1)
      visit "#{project.path}/detachable-volume"
      expect(page).to have_content "vol1"
      click_link "vol1"
      expect(page).to have_content "Overview"
    end
  end
end
