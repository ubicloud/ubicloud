# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw rename" do
  before do
    cli(%w[fw eu-central-h1/test-fw create])
    @fw = Firewall.first
  end

  it "renames object" do
    expect(cli(%w[fw eu-central-h1/test-fw rename new-name])).to eq "Firewall renamed to new-name\n"
    expect(@fw.reload.name).to eq "new-name"
  end

  it "handles failure when renaming object" do
    expect(cli(%w[fw eu-central-h1/test-fw rename] << "new name", status: 400)).to eq <<~END
      ! Unexpected response status: 400
      Details: Validation failed for following fields: name
        name: Name must only contain lowercase letters, numbers, and hyphens and have max length 63.
    END
    expect(@fw.reload.name).to eq "test-fw"
  end
end
