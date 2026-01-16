# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubCacheEntry" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_cache_entry
    admin_account_setup_and_login
  end

  it "displays the GithubCacheEntry instance page correctly" do
    click_link "GithubCacheEntry"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubCacheEntry"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubCacheEntry #{@instance.ubid}"
  end
end
