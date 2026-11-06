# frozen_string_literal: true

RSpec.describe TerraformGenerator do
  it "renders the Go and the examples of each defined type, by path in the module" do
    api = TerraformGenerator::Api.new(thing(create: {}))
    type = described_class.types(api, {thing: {}}).first
    expect(described_class.files(api, {thing: {}})).to eq [TerraformGenerator::Go.file(type), *TerraformGenerator::Hcl.files([type])].to_h
  end
end
