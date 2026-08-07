# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg create-backup-credentials" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "shows credentials including the CA certificate for metal databases" do
    @project.set_ff_postgres_backup_download_minio(true)
    create_minio_cluster_for_blob_storage
    allow(Config).to receive(:minio_service_project_id).and_return(Config.postgres_service_project_id)
    expiration = Time.now.utc + 36 * 60 * 60
    expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, assume_role: {access_key_id: "AKID", secret_access_key: "SECRET", session_token: "TOKEN", expiration:}))

    expect(cli(%w[pg eu-central-h1/test-pg create-backup-credentials])).to eq <<~END
      Bucket: #{@pg.timeline.ubid}
      Endpoint: https://walg-minio.minio.test:9000
      Region: us-east-1
      Access Key ID: AKID
      Secret Access Key: SECRET
      Session Token: TOKEN
      Expires At: #{expiration.iso8601}
      CA Certificate:
      dummy-certs
    END
  end

  it "shows credentials without a CA certificate for aws databases" do
    aws_location = Location.create(name: "loc-aws", display_name: "aws-loc", ui_name: "aws loc", visible: true, provider: "aws")
    @pg.timeline.update(location_id: aws_location.id)
    expiration = Time.now.utc + 36 * 60 * 60
    sts_client = Aws::STS::Client.new(stub_responses: true)
    expect(Aws::STS::Client).to receive(:new).and_return(sts_client)
    sts_client.stub_responses(:get_federation_token, credentials: {access_key_id: "AKID", secret_access_key: "SECRET", session_token: "TOKEN", expiration:})

    expect(cli(%w[pg eu-central-h1/test-pg create-backup-credentials])).to eq <<~END
      Bucket: #{@pg.timeline.ubid}
      Endpoint: https://s3.loc-aws.amazonaws.com
      Region: loc-aws
      Access Key ID: AKID
      Secret Access Key: SECRET
      Session Token: TOKEN
      Expires At: #{expiration.iso8601}
    END
  end
end
