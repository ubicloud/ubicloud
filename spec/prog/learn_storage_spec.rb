# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnStorage do
  subject(:ls) { described_class.new(Strand.new) }

  describe "#start" do
    it "exits, popping total storage and available storage" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("df -B1 --output=size,avail /var").and_return(<<EOS)
1B-blocks     Avail
494384795648 299711037440
EOS

      expect(ls).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(ls).to receive(:pop).with(total_storage_gib: 460, available_storage_gib: 274)
      ls.start
    end
  end

  describe Prog::LearnStorage::ParseDf do
    it "returns nil when parsing bad input" do
      expect {
        described_class.parse("")
      }.to raise_error RuntimeError, "BUG: unexpected output from df"
    end
  end
end
