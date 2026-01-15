# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupSysstat do
  subject(:ss) {
    described_class.new(Strand.create_with_id(sshable, prog: "SetupSysstat", label: "start"))
  }

  let(:sshable) { Sshable.create }

  describe "#start" do
    it "Sets it up and pops" do
      expect(ss.sshable).to receive(:_cmd).with("sudo host/bin/setup-sysstat")
      expect { ss.start }.to exit({"msg" => "Sysstat was setup"})
    end
  end
end
