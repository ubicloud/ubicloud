# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredential do
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
    if ENV["CLOVER_FREEZE"] != "1"
      sts_client = Aws::STS::Client.new(stub_responses: true)
      expect(Aws::STS::Client).to receive(:new).and_return(sts_client).at_least(:once)
      sts_client.stub_responses(:get_caller_identity, {account: "account-id"})
      expect(location_credential.aws_iam_account_id).to eq("account-id")
    end
  end
end
