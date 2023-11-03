# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresTimeline do
  subject(:postgres_timeline) { described_class.create_with_id }

  it "returns ubid as bucket name" do
    expect(postgres_timeline.bucket_name).to eq(postgres_timeline.ubid)
  end

  it "returns blob storage client from cache" do
    expect(Project).to receive(:[]).and_return(instance_double(Project, minio_clusters: [instance_double(MinioCluster, connection_strings: ["https://blob-endpoint"])]))
    expect(MinioClient).to receive(:new).and_return("dummy-client").once
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
    expect(postgres_timeline.blob_storage_client).to eq("dummy-client")
  end
end
