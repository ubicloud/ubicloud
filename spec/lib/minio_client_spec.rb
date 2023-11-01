# frozen_string_literal: true

RSpec.describe MinioClient do
  subject(:client) {
    described_class.new(endpoint: "http://endpoint", access_key: "dummy-access-key", secret_key: "dummy-secret-key")
  }

  let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }

  it "creates bucket" do
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    s3_client.stub_responses(:create_bucket)
    client.create_bucket(bucket_name: "bucket-name")
  end

  it "list objects" do
    expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
    s3_client.stub_responses(:list_objects_v2, {is_truncated: false, contents: [{key: "backup1"}, {key: "backup2"}]})

    objects = client.list_objects(bucket_name: "bucket-name", folder_path: "folder-path")
    expect(objects.count).to eq(2)
  end
end
