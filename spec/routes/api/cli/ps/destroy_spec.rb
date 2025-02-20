# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli ps destroy" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
  end

  it "destroys ps directly if -f option is given" do
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).to be_empty
    expect(cli(%w[ps eu-central-h1/test-ps destroy -f])).to eq "Private subnet, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).not_to be_empty
  end

  it "asks for confirmation if -f option is not given" do
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).to be_empty
    expect(cli(%w[ps eu-central-h1/test-ps destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this private subnet is not recoverable.
      Enter the following to confirm destruction of the private subnet: #{@ps.name}
    END
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).to be_empty
  end

  it "works on correct confirmation" do
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).to be_empty
    expect(cli(%w[--confirm test-ps ps eu-central-h1/test-ps destroy])).to eq "Private subnet, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).not_to be_empty
  end

  it "fails on incorrect confirmation" do
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).to be_empty
    expect(cli(%w[--confirm foo ps eu-central-h1/test-ps destroy], status: 400)).to eq "! Confirmation of private subnet name not successful.\n"
    expect(Semaphore.where(strand_id: @ps.id, name: "destroy")).to be_empty
  end
end
