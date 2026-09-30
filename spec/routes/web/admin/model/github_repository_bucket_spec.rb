# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubRepositoryBucket" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_repository_bucket
    admin_account_setup_and_login
  end

  it "displays the GithubRepositoryBucket instance page correctly" do
    click_link "GithubRepositoryBucket"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRepositoryBucket"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRepositoryBucket #{@instance.ubid}"
  end
end
