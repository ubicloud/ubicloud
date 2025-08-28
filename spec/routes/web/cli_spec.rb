# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "web shell" do
  let(:user) { create_account }

  let(:project) { user.projects.first }

  before do
    login(user.email)
    within("#desktop-menu") do
      click_link "Web Shell"
    end
  end

  it "supports running help cli commands" do
    expect(page.title).to eq "Ubicloud - Web Shell"
    fill_in "cli", with: "help -u pg list"
    click_button "Run"
    expect(page.find_by_id("cli-executed").text).to eq "help -u pg list"
    expect(page.find_by_id("cli-output").text).to eq "ubi pg list [options]"
  end

  it "ignores ubi prefix for command" do
    expect(page.title).to eq "Ubicloud - Web Shell"
    fill_in "cli", with: " ubi help -u pg list"
    click_button "Run"
    expect(page.find_by_id("cli-executed").text).to eq "help -u pg list"
    expect(page.find_by_id("cli-output").text).to eq "ubi pg list [options]"
  end

  it "supports creating objects using cli command" do
    fill_in "cli", with: "ps eu-central-h1/foo create"
    click_button "Run"
    ps = PrivateSubnet.first
    expect(ps.name).to eq "foo"
    expect(ps.display_location).to eq "eu-central-h1"
    expect(page.find_by_id("cli-executed").text).to eq "ps eu-central-h1/foo create"
    expect(page.find_by_id("cli-output").text).to eq "Private subnet created with id: #{ps.ubid}"
  end

  it "links ubids" do
    fill_in "cli", with: "ps eu-central-h1/foo create"
    click_button "Run"
    ps = PrivateSubnet.first
    click_link ps.ubid
    expect(page.title).to eq "Ubicloud - foo"
    expect(page).to have_current_path "#{project.path}#{ps.path}/overview", ignore_query: true
  end

  it "does not link ubids that cannot be matched" do
    fill_in "cli", with: "ps eu-central-h1/vm78zgv9w9et4mg6pba1frsz8n create"
    click_button "Run"
    ps = PrivateSubnet.first
    fill_in "cli", with: "ps list"
    click_button "Run"
    expect(page.html).to include " vm78zgv9w9et4mg6pba1frsz8n "
    expect(page.html).to include ">#{ps.ubid}</a>"
  end

  it "supports version" do
    fill_in "cli", with: "version"
    click_button "Run"
    expect(page.find_by_id("cli-output").text).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "shows program that would be executed" do
    fill_in "cli", with: "vm eu-central-h1/foo create 'a a'"
    click_button "Run"
    vm = Vm.first.update(ephemeral_net6: "::1234:0/120")
    expect(page.find_by_id("cli-executed").text).to eq "vm eu-central-h1/foo create 'a a'"
    expect(page.find_by_id("cli-output").text).to eq "VM created with id: #{vm.ubid}"
    expect(page).to have_content "Output:"

    fill_in "cli", with: "vm eu-central-h1/foo -6 ssh"
    click_button "Run"
    expect(page.find_by_id("cli-executed").text).to eq "vm eu-central-h1/foo -6 ssh"
    expect(page.find_by_id("cli-output").text).to eq "$ ssh -- ubi@::1234:2"
    expect(page).to have_content "Would execute:"
  end

  it "respects access permissions when using cli command" do
    AccessControlEntry.dataset.destroy
    fill_in "cli", with: "ps eu-central-h1/foo create"
    click_button "Run"
    expect(PrivateSubnet.count).to eq 0
    expect(page.find_by_id("cli-executed").text).to eq "ps eu-central-h1/foo create"
    expect(page.find_by_id("cli-output").text).to eq "! Unexpected response status: 403 Details: Sorry, you don't have permission to continue with this request."
  end

  it "supports scheduling multiple commands" do
    click_link "schedule execution of multiple commands"
    fill_in "Multiple commands, one per line", with: <<~END

      ps eu-central-h1/bar create
      ps eu-central-h1/bar destroy

      ps eu-central-h1/foo create
      ps eu-central-h1/foo show -f id

    END
    click_button "Run"
    ps = PrivateSubnet.first
    expect(ps.name).to eq "bar"
    expect(ps.display_location).to eq "eu-central-h1"
    expect(page.find_by_id("cli").value).to eq "ps eu-central-h1/bar destroy"
    expect(page.find_by_id("cli-executed").text).to eq "ps eu-central-h1/bar create"
    expect(page.find_by_id("cli-output").text).to eq "Private subnet created with id: #{ps.ubid}"
    expect(page.all(".next-clis").map(&:text)).to eq ["ps eu-central-h1/foo create", "ps eu-central-h1/foo show -f id"]

    click_button "Run"
    expect(page.find_by_id("cli").value).to eq "ps eu-central-h1/bar destroy"
    expect(page.find_by_id("cli-executed").text).to eq "ps eu-central-h1/bar destroy"
    expect(page.find_by_id("cli-output").text).to eq "Destroying this private subnet is not recoverable. Enter the following to confirm destruction of the private subnet: bar"
    expect(page.all(".next-clis").map(&:text)).to eq ["ps eu-central-h1/foo create", "ps eu-central-h1/foo show -f id"]

    fill_in "Confirmation", with: "bar"
    click_button "Run"
    expect(page.find_by_id("cli").value).to eq "ps eu-central-h1/foo create"
    expect(page.find_by_id("cli-executed").text).to eq "--confirm \"bar\" ps eu-central-h1/bar destroy"
    expect(page.find_by_id("cli-output").text).to eq "Private subnet, if it exists, is now scheduled for destruction"
    expect(page.all(".next-clis").map(&:text)).to eq ["ps eu-central-h1/foo show -f id"]
    expect(page).to have_content "Remaining commands:"

    click_button "Run"
    ps2 = PrivateSubnet.first(name: "foo")
    expect(page.find_by_id("cli").value).to eq "ps eu-central-h1/foo show -f id"
    expect(page.find_by_id("cli-executed").text).to eq "ps eu-central-h1/foo create"
    expect(page.find_by_id("cli-output").text).to eq "Private subnet created with id: #{ps2.ubid}"
    expect(page.all(".next-clis").map(&:text)).to eq []
    expect(page).to have_no_content "Remaining commands:"

    click_button "Run"
    expect(page.find_by_id("cli-executed").text).to eq "ps eu-central-h1/foo show -f id"
    expect(page.find_by_id("cli-output").text).to eq "id: #{ps2.ubid}"
    expect(page.all(".next-clis").map(&:text)).to eq []
  end

  describe "confirmation" do
    before do
      fill_in "cli", with: "ps eu-central-h1/foo create"
      click_button "Run"
      fill_in "cli", with: "ps eu-central-h1/foo destroy"
      click_button "Run"
      expect(page.find_by_id("cli-executed").text).to eq "ps eu-central-h1/foo destroy"
      expect(page.find_by_id("cli-output").text).to eq "Destroying this private subnet is not recoverable. Enter the following to confirm destruction of the private subnet: foo"
    end

    it "supports confirmation when using cli commands requiring confirmation" do
      fill_in "Confirmation", with: "foo"
      click_button "Run"
      expect(page.find_by_id("cli-executed").text).to eq "--confirm \"foo\" ps eu-central-h1/foo destroy"
      expect(page.find_by_id("cli-output").text).to eq "Private subnet, if it exists, is now scheduled for destruction"
    end

    it "handles invalid confirmation when using cli commands requiring confirmation" do
      fill_in "Confirmation", with: "foo bar"
      click_button "Run"
      expect(page.find_by_id("cli-executed").text).to eq "--confirm \"foo bar\" ps eu-central-h1/foo destroy"
      expect(page.find_by_id("cli-output").text).to eq "! Confirmation of private subnet name not successful."
    end
  end
end
