# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw update-description" do
  before do
    cli(%w[fw eu-central-h1/test-fw create])
    @fw = Firewall.first
  end

  it "updates description" do
    expect(cli(%w[fw eu-central-h1/test-fw update-description new-description])).to eq "Firewall description updated to new-description\n"
    expect(@fw.reload.description).to eq "new-description"
  end
end
