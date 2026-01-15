# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli gh remove-all-cache-entries" do
  it "removes all cache entries" do
    expect(Config).to receive(:github_app_name).and_return("test-app").at_least(:once)
    gi = GithubInstallation.create_with_id("6e3ae4a8-5474-8a01-b485-3b02ac649c5f", project_id: @project.id, installation_id: 12345678, name: "test-installation-name", type: "user")
    gp = GithubRepository.create_with_id("a58006b6-0879-8616-936a-62234e244f2f", installation_id: gi.id, name: "test-installation-name/test-repository-name")
    GithubCacheEntry.create_with_id("967f7e02-68f8-8a0e-9917-fd13d5f33501", repository_id: gp.id, key: "test-key-1", version: "test-version", scope: "test-scope", size: 10987654321, created_by: gp.id, committed_at: Time.now)

    expect(cli(%w[gh test-installation-name/test-repository-name remove-all-cache-entries])).to eq "All cache entries, if they exist, are now scheduled for destruction\n"
    st = Strand.first(prog: "Github::DeleteCacheEntries")
    expect(st.label).to eq "delete_entries"
  end

  it "handles case where there are no cache entries" do
    expect(Config).to receive(:github_app_name).and_return("test-app").at_least(:once)
    gi = GithubInstallation.create_with_id("6e3ae4a8-5474-8a01-b485-3b02ac649c5f", project_id: @project.id, installation_id: 12345678, name: "test-installation-name", type: "user")
    GithubRepository.create_with_id("a58006b6-0879-8616-936a-62234e244f2f", installation_id: gi.id, name: "test-installation-name/test-repository-name")

    expect(cli(%w[gh test-installation-name/test-repository-name remove-all-cache-entries])).to eq "All cache entries, if they exist, are now scheduled for destruction\n"
    st = Strand.first(prog: "Github::DeleteCacheEntries")
    expect(st).to be_nil
  end
end
