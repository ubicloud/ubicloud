# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredential do
  it "uses Aws::AssumeRoleCredentials when assume_role set" do
    lc = described_class.new(assume_role: "assume-role")
    creds = instance_double(Aws::AssumeRoleCredentials)
    expect(Aws::AssumeRoleCredentials).to receive(:new).with(role_arn: "assume-role", role_session_name: Config.hostname).and_return(creds)
    expect(lc.credentials).to be(creds)
  end
end
