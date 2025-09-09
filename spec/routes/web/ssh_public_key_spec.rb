# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  let(:user) { create_account }

  let(:project) { user.projects.first }

  before do
    login(user.email)
    visit "#{project.path}/ssh-public-key"
  end

  it "can navigate to management page from project page" do
    visit project.path
    click_link "Manage"
    expect(page.title).to eq "Ubicloud - SSH Public Keys"
  end

  it "does not allow access to SSH public keys in other projects" do
    click_link "Register SSH Public Key"
    fill_in "Name", with: "a"
    fill_in "Public Key", with: "a a"
    click_button "Register"
    pj = Project.create(name: "Other")
    SshPublicKey.first.update(project_id: pj.id)
    click_link "a"
    expect(page.status_code).to eq 404
  end

  it "support creating, updating, and deleting SSH public keys" do
    expect(page.title).to eq "Ubicloud - SSH Public Keys"
    click_link "Register SSH Public Key"
    expect(page.title).to eq "Ubicloud - Register SSH Public Key"

    click_button "Register"
    expect(page).to have_flash_error("Error registering SSH public key")
    expect(page).to have_content("is not present")

    fill_in "Name", with: "A A"
    fill_in "Public Key", with: "a"
    click_button "Register"
    expect(page).to have_flash_error("Error registering SSH public key")
    expect(page).to have_content("must only contain lowercase letters, numbers, and hyphens and have max length 63.")
    expect(page).to have_content("invalid SSH public key format")

    fill_in "Name", with: "a"
    fill_in "Public Key", with: "a a"
    expect(project.ssh_public_keys_dataset.all).to eq []
    click_button "Register"
    expect(page).to have_flash_notice("SSH public key with name a registered")
    expect(project.ssh_public_keys_dataset.select_order_map([:name, :public_key])).to eq [["a", "a a"]]

    expect(page.all("td a").map(&:text)).to eq ["a"]
    click_link "a"
    expect(page.title).to eq "Ubicloud - Update SSH Public Key"

    fill_in "Name", with: "A A"
    fill_in "Public Key", with: "a"
    click_button "Update"
    expect(page).to have_flash_error("Error updating SSH public key")
    expect(page).to have_content("must only contain lowercase letters, numbers, and hyphens and have max length 63.")
    expect(page).to have_content("invalid SSH public key format")

    fill_in "Name", with: "b"
    fill_in "Public Key", with: "b b"
    click_button "Update"
    expect(page).to have_flash_notice("SSH public key with name b updated")
    expect(project.ssh_public_keys_dataset.select_order_map([:name, :public_key])).to eq [["b", "b b"]]
    expect(page.all("td a").map(&:text)).to eq ["b"]

    click_link "b"
    btn = find ".delete-btn"
    page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

    expect(project.ssh_public_keys_dataset.all).to eq []
  end
end
