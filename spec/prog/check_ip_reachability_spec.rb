# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CheckIpReachability do
  subject(:cir) {
    described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}], prog: "CheckIpReachability"))
  }

  let(:vmh) { Prog::Vm::HostNexus.assemble("1.1.1.1").subject }

  describe "#start" do
    before do
      Address.create(cidr: "2001:db8::/64", routed_to_host_id: vmh.id)
      Address.create(cidr: "123.123.123.0/30", routed_to_host_id: vmh.id).populate_ipv4_addresses
    end

    it "checks the host and VM addresses and pops" do
      expect(cir.sshable).to receive(:_cmd).with("sudo host/bin/check-ip-reachability", stdin: '["1.1.1.1","123.123.123.0","123.123.123.1","123.123.123.2","123.123.123.3"]').and_return('{"unreachable":[]}')

      expect { cir.start }.to exit({"msg" => "all ip addresses are reachable"})
    end

    it "resolves an earlier page once all addresses are reachable" do
      page = Prog::PageNexus.assemble("page", ["UnreachableIpAddresses", vmh.ubid], vmh.ubid, resource_id: vmh.id).subject
      expect(cir.sshable).to receive(:_cmd).and_return('{"unreachable":[]}')

      expect { cir.start }.to exit({"msg" => "all ip addresses are reachable"})
      expect(page.reload.resolve_set?).to be true
    end

    it "retries unreachable addresses and pages on the fifth failed try" do
      expect(cir.sshable).to receive(:_cmd).exactly(5).times.and_return('{"unreachable":["123.123.123.1","123.123.123.3"]}')

      4.times do |i|
        expect { cir.start }.to nap(60)
        expect(cir.failed_tries).to eq(i + 1)
      end
      expect(Page.active.count).to eq 0

      expect { cir.start }.to nap(60)
      page = Page.from_tag_parts("UnreachableIpAddresses", vmh.ubid)
      expect(page.summary).to eq "#{vmh.ubid} has unreachable IP addresses: 123.123.123.1, 123.123.123.3"
      expect(page.details["unreachable"]).to eq ["123.123.123.1", "123.123.123.3"]
    end
  end
end
