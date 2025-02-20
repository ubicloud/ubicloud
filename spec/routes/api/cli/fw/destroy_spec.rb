# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw destroy" do
  before do
    cli(%w[fw eu-central-h1/test-fw create])
    @fw = Firewall.first
  end

  it "destroys fw directly if -f option is given" do
    expect(cli(%w[fw eu-central-h1/test-fw destroy -f])).to eq "Firewall, if it exists, is now scheduled for destruction\n"
    expect(@fw).not_to be_exist
  end

  it "asks for confirmation if -f option is not given" do
    expect(Semaphore.where(strand_id: @fw.id, name: "destroy")).to be_empty
    expect(cli(%w[fw eu-central-h1/test-fw destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this firewall is not recoverable.
      Enter the following to confirm destruction of the firewall: #{@fw.name}
    END
    expect(@fw).to be_exist
  end

  it "works on correct confirmation" do
    expect(cli(%w[--confirm test-fw fw eu-central-h1/test-fw destroy])).to eq "Firewall, if it exists, is now scheduled for destruction\n"
    expect(@fw).not_to be_exist
  end

  it "fails on incorrect confirmation" do
    expect(cli(%w[--confirm foo fw eu-central-h1/test-fw destroy], status: 400)).to eq "! Confirmation of firewall name not successful.\n"
    expect(@fw).to be_exist
  end
end
