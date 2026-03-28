# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::BillingResource do
  let(:project_id) { Project.generate_uuid }
  let(:resource_id) { PostgresResource.generate_uuid }
  let(:resource_tags) { {"env" => "prod", "region" => "us-west-2"} }
  let(:record) {
    BillingRecord.new(
      project_id:,
      resource_id:,
      resource_name: "pg-test",
      resource_tags:,
    )
  }

  it "serializes a billing record to UBID-keyed fields with resource_tags" do
    result = described_class.serialize_internal(record)
    expect(result).to eq(
      project_id: UBID.to_ubid(project_id),
      resource_id: UBID.to_ubid(resource_id),
      resource_name: "pg-test",
      resource_tags:,
    )
  end
end
