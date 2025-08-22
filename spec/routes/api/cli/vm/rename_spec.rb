# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm rename" do
  it "renames vm" do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    expect(cli(%w[vm eu-central-h1/test-vm rename new-name])).to eq "Virtual machine renamed to new-name\n"
    expect(Vm.first.name).to eq "new-name"
  end
end
