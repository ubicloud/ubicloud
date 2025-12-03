# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupNodeExporter do
  subject(:sn) {
    described_class.new(Strand.new(prog: "SetupNodeExporter"))
  }

  describe "#start" do
    it "Sets it up and pops" do
      sshable = create_mock_sshable(host: "1.1.1.1")
      expect(sn).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-node-exporter 1.9.1")
      expect { sn.start }.to exit({"msg" => "node exporter was setup"})
    end
  end
end
