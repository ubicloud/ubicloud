# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubRepositoryBucketPool" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_repository_bucket_pool
    admin_account_setup_and_login
  end

  it "displays the GithubRepositoryBucket instance page correctly" do
    click_link "GithubRepositoryBucketPool"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRepositoryBucketPool"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubRepositoryBucketPool #{@instance.ubid}"
  end
end
