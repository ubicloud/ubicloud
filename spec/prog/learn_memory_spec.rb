# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnMemory do
  subject(:lm) { described_class.new(Strand.new(stack: [])) }

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
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo /usr/sbin/dmidecode -t memory | fgrep Size:").and_return(four_units)
      expect(lm).to receive(:sshable).and_return(sshable)
      expect(lm).to receive(:pop).with(mem_gib: 64)
      lm.start
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

  # YYY: clean up having to test these simple accessors for every
  # prog, or worse yet, having to do with database access.
  describe "#sshable" do
    it "can load" do
      lm.strand.stack = [{"sshable_id" => "abc"}]
      expect(Sshable).to receive(:[]).with("abc")
      lm.sshable
    end
  end
end
