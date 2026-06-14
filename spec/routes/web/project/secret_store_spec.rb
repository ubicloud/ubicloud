# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "secret store" do
  let(:user) { create_account }
  let(:project) { user.projects.first }

  before do
    login(user.email)
  end

  it "navigates from the sidebar and shows an empty state" do
    visit project.path
    click_link "Secret Stores", match: :first
    expect(page.title).to eq "Ubicloud - Secret Stores"
    expect(page).to have_content("No Secret Stores")
  end

  it "creates, views, and manages secrets, then deletes the store" do
    visit "#{project.path}/secret-store"
    click_link "Create Secret Store"
    expect(page.title).to eq "Ubicloud - Create Secret Store"

    # validation error re-renders the form
    fill_in "Name", with: "Invalid Name"
    click_button "Create"
    expect(page).to have_content("must only contain lowercase letters")

    fill_in "Name", with: "my-store"
    fill_in "Description (optional)", with: "prod secrets"
    click_button "Create"
    expect(page).to have_flash_notice("Secret store 'my-store' created")

    store = SecretStore.first(name: "my-store")
    expect(store.description).to eq "prod secrets"
    expect(page.title).to eq "Ubicloud - my-store"
    expect(page).to have_content("No secrets yet.")

    # set a secret
    fill_in "Key", with: "db-pass"
    fill_in "Value", with: "p@ssw0rd"
    click_button "Set Secret"
    expect(page).to have_flash_notice("Secret 'db-pass' saved")
    expect(store.secrets_dataset.first(key: "db-pass").value).to eq "p@ssw0rd"
    # the (masked) value is present in the page for revealing
    expect(page).to have_content("p@ssw0rd")

    # update the secret in place
    fill_in "Key", with: "db-pass"
    fill_in "Value", with: "rotated"
    click_button "Set Secret"
    expect(page).to have_flash_notice("Secret 'db-pass' saved")
    expect(store.secrets_dataset.where(key: "db-pass").count).to eq 1
    expect(store.secrets_dataset.first(key: "db-pass").value).to eq "rotated"

    # rename and re-describe via settings
    fill_in "Name", with: "renamed-store"
    fill_in "Description", with: "updated"
    click_button "Save"
    expect(page).to have_flash_notice("Secret store updated")
    store.reload
    expect(store.name).to eq "renamed-store"
    expect(store.description).to eq "updated"

    # delete the secret
    within "#secret-db-pass" do
      click_button "Delete"
    end
    expect(page).to have_flash_notice("Secret 'db-pass' deleted")
    expect(store.secrets_dataset.first(key: "db-pass")).to be_nil

    # delete the store
    click_button "Delete secret store"
    expect(page).to have_flash_notice("Secret store deleted")
    expect(SecretStore[store.id]).to be_nil
  end

  it "returns 404 for a store in another project" do
    store = SecretStore.create(project_id: project.id, name: "my-store")
    other = Project.create(name: "Other")
    store.update(project_id: other.id)

    visit "#{project.path}/secret-store/#{store.ubid}"
    expect(page.status_code).to eq 404
  end

  describe "with view-only access" do
    before do
      @store = SecretStore.create(project_id: project.id, name: "my-store")
      @store.add_secret(key: "k1", value: "v1")
      AccessControlEntry.dataset.destroy
      AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["SecretStore:view"])
    end

    it "can view values but cannot see edit controls or the create button" do
      visit "#{project.path}/secret-store"
      expect(page).to have_no_content("Create Secret Store")

      visit "#{project.path}/secret-store/#{@store.ubid}"
      expect(page.status_code).to eq 200
      expect(page).to have_content("v1")
      expect(page).to have_no_button("Set Secret")
      expect(page).to have_no_button("Delete secret store")
      expect(page).to have_no_button("Save")
    end
  end
end
