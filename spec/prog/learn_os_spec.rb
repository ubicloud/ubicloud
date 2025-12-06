# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnOs do
  subject(:lo) { described_class.new(Strand.new) }

  let(:sshable) { Sshable.new }

  describe "#start" do
    it "exits, saving OS version" do
      expect(sshable).to receive(:_cmd).with("lsb_release --short --release").and_return("24.04")
      allow(lo).to receive(:sshable).and_return(sshable)
      expect { lo.start }.to exit(os_version: "ubuntu-24.04")
    end
  end
end
