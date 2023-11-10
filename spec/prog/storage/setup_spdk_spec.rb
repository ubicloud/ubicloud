# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::SetupSpdk do
  subject(:ss) {
    described_class.new(Strand.new(prog: "SetupSpdk"))
  }

  describe "#start" do
    it "exits after setting up SPDK" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk install")
      expect(ss).to receive(:sshable).and_return(sshable)
      expect { ss.start }.to exit({"msg" => "SPDK was setup"})
    end
  end
end
