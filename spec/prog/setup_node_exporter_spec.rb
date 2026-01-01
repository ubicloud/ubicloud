# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupNodeExporter do
  subject(:sn) {
    described_class.new(Strand.create_with_id(sshable_id, prog: "SetupNodeExporter", label: "start"))
  }

  let(:sshable_id) { Sshable.generate_uuid }
  let(:sshable) { Sshable.create_with_id(sshable_id) }

  describe "#start" do
    it "Sets it up and pops" do
      sshable
      expect(sn.sshable).to receive(:_cmd).with("sudo host/bin/setup-node-exporter 1.9.1")
      expect { sn.start }.to exit({"msg" => "node exporter was setup"})
    end
  end
end
