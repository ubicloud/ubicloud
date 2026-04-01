# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredential do
  context "with AWS credentials" do
    subject(:location_credential) {
      described_class.create_with_id(location.id, assume_role: "assume-role")
    }

    let(:location) {
      Location.create(
        name: "test-location",
        display_name: "display-name",
        ui_name: "ui-name",
        visible: true,
        provider: "aws"
      )
    }

    it "uses Aws::AssumeRoleCredentials when assume_role set" do
      creds = instance_double(Aws::AssumeRoleCredentials)
      expect(Aws::AssumeRoleCredentials).to receive(:new).with(role_arn: "assume-role", role_session_name: Config.aws_role_session_name).and_return(creds)
      expect(location_credential.credentials).to be(creds)
    end

    it "gets account id from sts" do
      sts_client = Aws::STS::Client.new(stub_responses: true)
      expect(Aws::STS::Client).to receive(:new).and_return(sts_client).at_least(:once)
      sts_client.stub_responses(:get_caller_identity, {account: "account-id"})
      expect(location_credential.aws_iam_account_id).to eq("account-id")
    end

    it "returns AWS IAM client for iam_client" do
      creds = instance_double(Aws::AssumeRoleCredentials)
      expect(Aws::AssumeRoleCredentials).to receive(:new).and_return(creds)
      iam = instance_double(Aws::IAM::Client)
      expect(Aws::IAM::Client).to receive(:new).with(region: "test-location", credentials: creds).and_return(iam)
      expect(location_credential.iam_client).to be(iam)
    end
  end

  context "with AWS access key credentials" do
    subject(:location_credential) {
      described_class.create_with_id(location.id,
        access_key: "AKIAIOSFODNN7EXAMPLE",
        secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    }

    let(:location) {
      Location.create(
        name: "us-east-1",
        display_name: "US East 1",
        ui_name: "US East 1",
        visible: true,
        provider: "aws"
      )
    }

    it "uses Aws::Credentials when access_key and secret_key are set" do
      creds = location_credential.credentials
      expect(creds).to be_a(Aws::Credentials)
    end

    it "returns an EC2 client" do
      ec2 = instance_double(Aws::EC2::Client)
      expect(Aws::EC2::Client).to receive(:new).and_return(ec2)
      expect(location_credential.client).to be(ec2)
    end

    it "returns an AWS IAM client when credentials_json is not set" do
      iam = instance_double(Aws::IAM::Client)
      expect(Aws::IAM::Client).to receive(:new).and_return(iam)
      expect(location_credential.iam_client).to be(iam)
    end
  end
end
