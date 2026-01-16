# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubRepository" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_repository
    admin_account_setup_and_login
  end

  it "displays the GithubRepository instance page correctly" do
    click_link "GithubRepository"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRepository"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRepository #{@instance.ubid}"
  end
end
