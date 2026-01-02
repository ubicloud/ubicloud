# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupSysstat do
  subject(:ss) {
    described_class.new(Strand.create_with_id(sshable_id, prog: "SetupSysstat", label: "start"))
  }

  let(:sshable_id) { Sshable.generate_uuid }
  let(:sshable) { Sshable.create_with_id(sshable_id) }

  describe "#start" do
    it "Sets it up and pops" do
      sshable
      expect(ss.sshable).to receive(:_cmd).with("sudo host/bin/setup-sysstat")
      expect { ss.start }.to exit({"msg" => "Sysstat was setup"})
    end
  end
end
