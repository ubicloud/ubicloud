# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredentialAws do
  subject(:location_credential_aws) {
    described_class.create_with_id(location.id, assume_role: "assume-role")
  }

  let(:location) {
    Location.create(
      name: "test-location",
      display_name: "display-name",
      ui_name: "ui-name",
      visible: true,
      provider: "aws",
    )
  }

  it "uses Aws::AssumeRoleCredentials when assume_role set" do
    expect(Aws::AssumeRoleCredentials).to receive(:new).with(role_arn: "assume-role", role_session_name: Config.aws_role_session_name)
    location_credential_aws.credentials
  end

  it "uses Aws::Credentials when access_key and secret_key set" do
    key_location = Location.create(
      name: "test-location-keys",
      display_name: "display-name-keys",
      ui_name: "ui-name-keys",
      visible: true,
      provider: "aws",
    )
    lca = described_class.create_with_id(key_location.id, access_key: "test-key", secret_key: "test-secret")
    expect(Aws::Credentials).to receive(:new).with("test-key", "test-secret")
    lca.credentials
  end

  it "gets account id from sts" do
    sts_client = Aws::STS::Client.new(stub_responses: true)
    expect(Aws::STS::Client).to receive(:new).and_return(sts_client).at_least(:once)
    sts_client.stub_responses(:get_caller_identity, {account: "account-id"})
    expect(location_credential_aws.aws_iam_account_id).to eq("account-id")
  end

  it "returns an EC2 client" do
    creds = instance_double(Aws::AssumeRoleCredentials)
    expect(Aws::AssumeRoleCredentials).to receive(:new).and_return(creds)
    ec2_client = instance_double(Aws::EC2::Client)
    expect(Aws::EC2::Client).to receive(:new).with(region: "test-location", credentials: creds).and_return(ec2_client)
    expect(location_credential_aws.client).to be(ec2_client)
  end

  it "returns an IAM client" do
    creds = instance_double(Aws::AssumeRoleCredentials)
    expect(Aws::AssumeRoleCredentials).to receive(:new).and_return(creds)
    iam_client = instance_double(Aws::IAM::Client)
    expect(Aws::IAM::Client).to receive(:new).with(region: "test-location", credentials: creds).and_return(iam_client)
    expect(location_credential_aws.iam_client).to be(iam_client)
  end
end
