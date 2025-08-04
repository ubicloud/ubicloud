# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe BillingRecord do
  it "can filter for active records" do
    expected = described_class.create(
      project_id: "50089dcf-b472-8ad2-9ca6-b3e70d12759d",
      resource_id: "2464de61-7501-8374-9ab0-416caebe31da",
      resource_name: "whatever",
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")["id"],
      amount: 1
    )
    expect(described_class.active.all).to eq([expected])
  end

  it "returns duration as 1 for amount based billing rates" do
    [described_class.new(billing_rate_id: BillingRate.from_resource_properties("GitHubRunnerMinutes", "standard-2", "global")["id"]),
      described_class.new(billing_rate_id: BillingRate.from_resource_properties("InferenceTokens", "test-model", "global")["id"])].each do |br|
      expect(br.duration(Time.now, Time.now)).to eq(1)
    end
  end
end
