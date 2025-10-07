# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  let(:user) { create_account }

  let(:project) { user.projects.first }

  before do
    login(user.email)
    visit "#{project.path}/vm-init-script"
  end

  it "can navigate to management page from project page" do
    visit project.path
    click_link "Manage Virtual Machine Init Scripts"
    expect(page.title).to eq "Ubicloud - Virtual Machine Init Scripts"
  end

  it "does not allow access to VM init scripts in other projects" do
    click_link "Register VM Init Script"
    fill_in "Name", with: "a"
    fill_in "Script", with: "a a"
    click_button "Register"
    pj = Project.create(name: "Other")
    VmInitScript.first.update(project_id: pj.id)
    click_link "a"
    expect(page.status_code).to eq 404
  end

  it "support creating, updating, and deleting VM init scripts" do
    expect(page.title).to eq "Ubicloud - Virtual Machine Init Scripts"
    click_link "Register VM Init Script"
    expect(page.title).to eq "Ubicloud - Register VM Init Script"

    click_button "Register"
    expect(page).to have_flash_error("Error registering virtual machine init script")
    expect(page).to have_content("is not present")

    fill_in "Name", with: "A A"
    fill_in "Script", with: "a"
    click_button "Register"
    expect(page).to have_flash_error("Error registering virtual machine init script")
    expect(page).to have_content("must only contain lowercase letters, numbers, and hyphens and have max length 63.")

    fill_in "Name", with: "a"
    fill_in "Script", with: "a a"
    expect(project.vm_init_scripts_dataset.all).to eq []
    click_button "Register"
    expect(page).to have_flash_notice("Virtual machine init script with name a registered")
    expect(project.vm_init_scripts_dataset.select_order_map([:name, :script])).to eq [["a", "a a"]]

    expect(page.all("td a").map(&:text)).to eq ["a"]
    click_link "a"
    expect(page.title).to eq "Ubicloud - Update VM Init Script"

    fill_in "Name", with: "A A"
    fill_in "Script", with: "a"
    click_button "Update"
    expect(page).to have_flash_error("Error updating virtual machine init script")
    expect(page).to have_content("must only contain lowercase letters, numbers, and hyphens and have max length 63.")

    fill_in "Name", with: "b"
    fill_in "Script", with: "b b"
    click_button "Update"
    expect(page).to have_flash_notice("Virtual machine init script with name b updated")
    expect(project.vm_init_scripts_dataset.select_order_map([:name, :script])).to eq [["b", "b b"]]
    expect(page.all("td a").map(&:text)).to eq ["b"]

    click_link "b"
    btn = find ".delete-btn"
    page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

    expect(project.vm_init_scripts_dataset.all).to eq []
  end
end
