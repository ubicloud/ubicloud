# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnMemory do
  subject(:lm) { described_class.new(Strand.new) }

  let(:four_units) do
    <<EOS

	Size: 16 GB
	Size: 16 GB
	Size: 16 GB
	Size: 16 GB
EOS
  end

  describe "#start" do
    it "exits, saving the number of memory" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("sudo /usr/sbin/dmidecode -t memory | fgrep Size:").and_return(four_units)
      expect(lm).to receive(:sshable).and_return(sshable)
      expect { lm.start }.to exit({mem_gib: 64})
    end
  end

  describe "#parse_sum" do
    it "crashes if an unfamiliar unit is provided" do
      expect {
        lm.parse_sum(<<EOS)
	Size: 16384 MB
EOS
      }.to raise_error RuntimeError, "BUG: unexpected dmidecode unit"
    end
  end
end
