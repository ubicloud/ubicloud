# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli gh remove-all-cache-entries" do
  it "removes all cache entries" do
    expect(Config).to receive(:github_app_name).and_return("test-app").at_least(:once)
    gi = GithubInstallation.create_with_id("6e3ae4a8-5474-8a01-b485-3b02ac649c5f", project_id: @project.id, installation_id: 12345678, name: "test-installation-name", type: "user")
    gp = GithubRepository.create_with_id("a58006b6-0879-8616-936a-62234e244f2f", installation_id: gi.id, name: "test-installation-name/test-repository-name")
    ge1 = GithubCacheEntry.create_with_id("967f7e02-68f8-8a0e-9917-fd13d5f33501", repository_id: gp.id, key: "test-key-1", version: "test-version", scope: "test-scope", size: 10987654321, created_by: gp.id, committed_at: Time.now)
    ge2 = GithubCacheEntry.create_with_id("967f7e02-68f8-8a0e-9917-fd13d5f33502", repository_id: gp.id, key: "test-key-2", version: "test-version", scope: "test-scope", size: 10987654321, created_by: gp.id, committed_at: Time.now)
    ge3 = GithubCacheEntry.create_with_id("967f7e02-68f8-8a0e-9917-fd13d5f33503", repository_id: gp.id, key: "test-key-3", version: "test-version", scope: "test-scope", size: 10987654321, created_by: gp.id, committed_at: Time.now)
    client = instance_double(Aws::S3::Client)
    expect(Aws::S3::Client).to receive(:new).and_return(client).exactly(3).times
    expect(client).to receive(:delete_object).with(bucket: gp.bucket_name, key: ge1.blob_key)
    expect(client).to receive(:delete_object).with(bucket: gp.bucket_name, key: ge2.blob_key)
    expect(client).to receive(:delete_object).with(bucket: gp.bucket_name, key: ge3.blob_key)

    expect(cli(%w[gh test-installation-name/test-repository-name remove-all-cache-entries])).to eq "All cache entries, if they exist, are now scheduled for destruction\n"

    # Run the strand to completion
    strand = Strand[gp.id]
    expect(strand).not_to be_nil
    expect(strand.prog).to eq("Github::DeleteCacheEntries")

    # Run the strand until all entries are deleted
    # Need to run 4 times: start + delete 3 entries
    4.times do
      expect(strand.run).not_to be_nil
    end

    # Verify all entries are deleted
    expect(ge1.exists?).to be false
    expect(ge2.exists?).to be false
    expect(ge3.exists?).to be false
  end

  it "handles case where there are no cache entries" do
    expect(Config).to receive(:github_app_name).and_return("test-app").at_least(:once)
    gi = GithubInstallation.create_with_id("6e3ae4a8-5474-8a01-b485-3b02ac649c5f", project_id: @project.id, installation_id: 12345678, name: "test-installation-name", type: "user")
    GithubRepository.create_with_id("a58006b6-0879-8616-936a-62234e244f2f", installation_id: gi.id, name: "test-installation-name/test-repository-name")

    expect(cli(%w[gh test-installation-name/test-repository-name remove-all-cache-entries])).to eq "All cache entries, if they exist, are now scheduled for destruction\n"
  end
end
