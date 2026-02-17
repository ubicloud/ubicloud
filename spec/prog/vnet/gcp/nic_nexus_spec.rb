# frozen_string_literal: true

RSpec.describe Prog::Vnet::Gcp::NicNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.new }
  let(:nic) { instance_double(Nic, id: "test-nic-id") }

  before do
    nx.instance_variable_set(:@nic, nic)
  end

  describe "#start" do
    it "hops to wait" do
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "destroys the nic and pops" do
      expect(nic).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
    end
  end
end
