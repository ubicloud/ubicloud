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

    it "can create and view data disk" do
      visit "#{project.path}/detachable-volume"
      expect(page).to have_content "No data disks"
      click_link "Create Data Disk"
      expect(page.title).to eq("Ubicloud - Create Data Disk")
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

    it "shows an error when creating a duplicate data disk" do
      DetachableVolume.create(name: "vol1", project_id: project.id, size_gib: 10)

      visit "#{project.path}/detachable-volume/create"
      expect(page.title).to eq("Ubicloud - Create Data Disk")
      fill_in "Name", with: "vol1"
      choose option: "10"
      click_button "Create"

      expect(page.title).to eq("Ubicloud - Create Data Disk")
      expect(page).to have_content('Data disk with name "vol1" already exists.')
      expect(DetachableVolume.where(project_id: project.id).count).to eq(1)
    end
  end
end
