# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubCustomLabel" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_custom_label
    admin_account_setup_and_login
  end

  it "displays the GithubCustomLabel instance page correctly" do
    click_link "GithubCustomLabel"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubCustomLabel"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubCustomLabel #{@instance.ubid}"
  end
end
