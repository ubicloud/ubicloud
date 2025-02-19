# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb destroy" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    cli(%W[lb eu-central-h1/test-lb create #{@ps.ubid} 12345 54321])
    @lb = LoadBalancer.first
  end

  it "destroys load balancer directly if -f option is given" do
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).to be_empty
    expect(cli(%w[lb eu-central-h1/test-lb destroy -f])).to eq "Load balancer, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).not_to be_empty
  end

  it "asks for confirmation if -f option is not given" do
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).to be_empty
    expect(cli(%w[lb eu-central-h1/test-lb destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this load balancer is not recoverable.
      Enter the following to confirm destruction of the load balancer: #{@lb.name}
    END
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).to be_empty
  end

  it "works on correct confirmation" do
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).to be_empty
    expect(cli(%w[--confirm test-lb lb eu-central-h1/test-lb destroy])).to eq "Load balancer, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).not_to be_empty
  end

  it "fails on incorrect confirmation" do
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).to be_empty
    expect(cli(%w[--confirm foo lb eu-central-h1/test-lb destroy], status: 400)).to eq "! Confirmation of load balancer name not successful.\n"
    expect(Semaphore.where(strand_id: @lb.id, name: "destroy")).to be_empty
  end
end
