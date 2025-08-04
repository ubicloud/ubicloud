# frozen_string_literal: true

require_relative "../model/spec_helper"
require "socket"
RSpec.describe Prog::ResolveGloballyBlockedDnsnames do
  subject(:rgbd) {
    described_class.new(Strand.new(prog: "ResolveGloballyBlockedDnsnames", label: "wait"))
  }

  let(:globally_blocked_dnsname) { GloballyBlockedDnsname.create(dns_name: "example.com", last_check_at: "2023-10-19 19:27:47 +0000") }

  describe "#wait" do
    before do
      globally_blocked_dnsname
    end

    it "resolves dnsnames to ip addresses and updates records" do
      expect(Socket).to receive(:getaddrinfo).with("example.com", nil).and_return([[nil, nil, nil, "1.1.1.1"], [nil, nil, nil, "2a00:1450:400e:811::200e"], [nil, nil, nil, "1.1.1.1"]])
      expect(Time).to receive(:now).and_return(Time.new("2023-10-19 23:27:47 +0000")).at_least(:once)
      expect { rgbd.wait }.to nap(60 * 60)

      expect(globally_blocked_dnsname.reload.ip_list.map(&:to_s).sort).to eq(["1.1.1.1", "2a00:1450:400e:811::200e"])
    end

    it "skips if socket fails" do
      expect(Socket).to receive(:getaddrinfo).with("example.com", nil).and_raise(SocketError)
      expect { rgbd.wait }.to nap(60 * 60)

      expect(globally_blocked_dnsname.reload.ip_list).to be_nil
    end
  end
end
