# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ApiKey do
  let(:prj) {
    Project.create(name: "test-project")
  }

  it "can be created and rotated" do
    expect(prj.api_keys.count).to eq 0
    api_key = described_class.create(owner_table: "project", owner_id: prj.id, used_for: "inference_endpoint", project_id: prj.id)
    expect(prj.reload.api_keys.count).to eq 1
    key = api_key.key
    api_key.rotate
    expect(api_key.key).not_to eq key
  end

  it "can be created and rotated2" do
    expect { described_class.create(owner_table: "invalid-owner", owner_id: "2d1784a8-f70d-48e7-92b1-3f428381d62f", used_for: "inference_endpoint", project_id: prj.id) }.to raise_error("Invalid owner_table: invalid-owner")
  end
end
