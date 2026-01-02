# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnOs do
  subject(:lo) {
    sshable
    described_class.new(Strand.create_with_id(sshable_id, prog: "LearnOs", label: "start"))
  }

  let(:sshable_id) { Sshable.generate_uuid }
  let(:sshable) { Sshable.create_with_id(sshable_id) }

  describe "#start" do
    it "exits, saving OS version" do
      expect(lo.sshable).to receive(:_cmd).with("lsb_release --short --release").and_return("24.04")
      expect { lo.start }.to exit(os_version: "ubuntu-24.04")
    end
  end
end
