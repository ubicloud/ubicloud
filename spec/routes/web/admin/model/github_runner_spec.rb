# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubRunner" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_runner
    admin_account_setup_and_login
  end

  it "displays the GithubRunner instance page correctly" do
    click_link "GithubRunner"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRunner - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRunner #{@instance.ubid}"
  end
end
