# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupSpdk do
  subject(:ss) {
    described_class.new(Strand.new(prog: "SetupSpdk",
      stack: [{sshable_id: "bogus"}]))
  }

  describe "#start" do
    it "transitions to start_service" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo bin/setup-spdk")
      expect(ss).to receive(:sshable).and_return(sshable)
      expect { ss.start }.to hop("enable_service")
    end
  end

  describe "#enable_service" do
    it "enables spdk and exits" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo systemctl enable home-spdk-hugepages.mount")
      expect(sshable).to receive(:cmd).with("sudo systemctl enable spdk")
      expect(ss).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(ss).to receive(:pop).with("SPDK was setup")
      ss.enable_service
    end
  end
end
