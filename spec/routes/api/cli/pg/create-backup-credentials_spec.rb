# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg create-backup-credentials" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  def stub_aws_credentials
    aws_location = Location.create(name: "loc-aws", display_name: "aws-loc", ui_name: "aws loc", visible: true, provider: "aws")
    @pg.timeline.update(location_id: aws_location.id)
    expiration = Time.now.utc + 36 * 60 * 60
    sts_client = Aws::STS::Client.new(stub_responses: true)
    expect(Aws::STS::Client).to receive(:new).and_return(sts_client)
    sts_client.stub_responses(:get_federation_token, credentials: {access_key_id: "AKID", secret_access_key: "SECRET", session_token: "TOKEN", expiration:})
    expiration
  end

  it "shows credentials for metal databases" do
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
    END
  end

  it "shows credentials for aws databases" do
    expiration = stub_aws_credentials

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

  it "emits a shell-sourceable environment with --format env" do
    stub_aws_credentials

    expect(cli(%w[pg eu-central-h1/test-pg create-backup-credentials --format env])).to eq <<~END
      export AWS_ACCESS_KEY_ID='AKID'
      export AWS_SECRET_ACCESS_KEY='SECRET'
      export AWS_SESSION_TOKEN='TOKEN'
      export WALG_S3_PREFIX='s3://#{@pg.timeline.ubid}'
      export AWS_ENDPOINT='https://s3.loc-aws.amazonaws.com'
      export AWS_REGION='loc-aws'
      export AWS_S3_FORCE_PATH_STYLE='true'
    END
  end

  it "emits JSON with --format json" do
    expiration = stub_aws_credentials

    expect(cli(%w[pg eu-central-h1/test-pg create-backup-credentials --format json])).to eq(<<~END)
      {"bucket":"#{@pg.timeline.ubid}","endpoint":"https://s3.loc-aws.amazonaws.com","region":"loc-aws","access_key_id":"AKID","secret_access_key":"SECRET","session_token":"TOKEN","expiration":"#{expiration.iso8601}"}
    END
  end

  it "returns an error for an unrecognized format" do
    body = cli(%w[pg eu-central-h1/test-pg create-backup-credentials --format yaml], status: 400)
    expect(body).to include("must be one of: table, env, json").and include('"yaml"')
  end
end
