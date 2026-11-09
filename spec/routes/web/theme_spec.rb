# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "theme" do
  let(:user) { create_account }

  before do
    login(user.email)
  end

  it "switches the theme from the account menu" do
    visit "/project"
    expect(page.find("html")[:class]).to eq "theme-system"
    expect(page.find("#topbar button[aria-checked=true]").text).to eq "System"

    click_button "Dark"
    expect(page).to have_current_path "/project"
    expect(page.find("html")[:class]).to eq "theme-dark"
    expect(page.find("#topbar button[aria-checked=true]").text).to eq "Dark"

    click_button "Light"
    expect(page.find("html")[:class]).to eq "theme-light"
    expect(page.find("#topbar button[aria-checked=true]").text).to eq "Light"

    click_button "System"
    expect(page.find("html")[:class]).to eq "theme-system"
    expect(page.find("#topbar button[aria-checked=true]").text).to eq "System"
  end
end
