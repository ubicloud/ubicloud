# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli gh remove-cache-entry" do
  it "removes cache entry" do
    expect(Config).to receive(:github_app_name).and_return("test-app").at_least(:once)
    gi = GithubInstallation.create_with_id("6e3ae4a8-5474-8a01-b485-3b02ac649c5f", project_id: @project.id, installation_id: 12345678, name: "test-installation-name", type: "user")
    gp = GithubRepository.create_with_id("a58006b6-0879-8616-936a-62234e244f2f", installation_id: gi.id, name: "test-installation-name/test-repository-name")
    ge = GithubCacheEntry.create_with_id("967f7e02-68f8-8a0e-9917-fd13d5f33501", repository_id: gp.id, key: "test-key", version: "test-version", scope: "test-scope", size: 10987654321, created_by: gp.id)
    client = instance_double(Aws::S3::Client)
    expect(Aws::S3::Client).to receive(:new).and_return(client)
    expect(client).to receive(:delete_object).with(bucket: gp.bucket_name, key: ge.blob_key)
    expect(client).to receive(:abort_multipart_upload).with(bucket: gp.bucket_name, key: ge.blob_key, upload_id: nil)

    cli(%w[gh test-installation-name/test-repository-name remove-cache-entry gejszqw0k8z24k4bzt4ynyctg2])
    expect(ge.exists?).to be false
  end
end
