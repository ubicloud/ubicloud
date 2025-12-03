# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupSysstat do
  subject(:ss) {
    described_class.new(Strand.new(prog: "SetupSysstat"))
  }

  describe "#start" do
    it "Sets it up and pops" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-sysstat")
      expect(ss).to receive(:sshable).and_return(sshable)
      expect { ss.start }.to exit({"msg" => "Sysstat was setup"})
    end
  end
end
