# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnStorage do
  subject(:ls) { described_class.new(Strand.new(stack: [{sshable_id: "bogus"}])) }

  describe "#start" do
    it "exits, popping total storage and available storage" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("df -h --output=size /var").and_return(<<EOS)
      Size
      500G
EOS
      expect(sshable).to receive(:cmd).with("df -h --output=avail /var").and_return(<<EOS)
      Avail
       200G
EOS
      expect(ls).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(ls).to receive(:pop).with(total_storage_gib: 500, available_storage_gib: 195)
      ls.start
    end
  end

  describe "#parse_size_gib" do
    it "can parse gigabytes" do
      expect(
        ls.parse_size_gib("/var", <<EOS)
            Size
            460G
EOS
      ).to eq(460)
    end

    it "can parse terabytes" do
      expect(
        ls.parse_size_gib("/var", <<EOS)
            Size
            5T
EOS
      ).to eq(5 * 1024)
    end

    it "crashes if an unfamiliar unit is provided" do
      expect {
        ls.parse_size_gib("/var", <<EOS)
        Size
        460M
EOS
      }.to raise_error RuntimeError, "BUG: unexpected storage size unit: M"
    end

    it "crashes if more than one size is provided" do
      expect {
        ls.parse_size_gib("/var", <<EOS)
          Size
          460G
          420G
EOS
      }.to raise_error RuntimeError, "BUG: expected one size for /var, but received: [460, 420]"
    end
  end
end
