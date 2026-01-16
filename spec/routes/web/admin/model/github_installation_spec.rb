# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubInstallation" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_installation
    admin_account_setup_and_login
  end

  it "displays the GithubInstallation instance page correctly" do
    click_link "GithubInstallation"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubInstallation - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubInstallation #{@instance.ubid}"
  end
end
