# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli ps rename" do
  it "renames private subnet" do
    cli(%w[ps eu-central-h1/test-ps create])
    expect(cli(%w[ps eu-central-h1/test-ps rename new-name])).to eq "Private subnet renamed to new-name\n"
    expect(PrivateSubnet.first.name).to eq "new-name"
  end
end
