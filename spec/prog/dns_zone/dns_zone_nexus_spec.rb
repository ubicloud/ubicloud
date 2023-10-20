# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::DnsZone::DnsZoneNexus do
  subject(:nx) { described_class.new(Strand.new(id: DnsZone.generate_uuid)) }

  let(:dns_zone) { DnsZone.create_with_id(project_id: SecureRandom.uuid, name: "postgres.ubicloud.com") }
  let(:dns_server) { DnsServer.create_with_id(name: "ns.ubicloud.com") }
  let(:vm) { instance_double(Vm, id: "788525ed-d6f0-4937-a844-323d4fd91946") }
  let(:sshable) { instance_double(Sshable) }

  before do
    allow(vm).to receive(:sshable).and_return(sshable)
    allow(dns_server).to receive(:vms).and_return([vm])
    allow(dns_zone).to receive(:dns_servers).and_return([dns_server])
    allow(nx).to receive(:dns_zone).and_return(dns_zone)
  end

  describe "#wait" do
    it "hops to refresh_dns_servers if refresh_dns_servers semaphore is set" do
      expect(nx).to receive(:when_refresh_dns_servers_set?).and_yield
      expect { nx.wait }.to hop("refresh_dns_servers")
    end

    it "naps if refresh_dns_servers semaphore is not set" do
      expect(nx).to receive(:when_refresh_dns_servers_set?)
      expect { nx.wait }.to nap(10)
    end
  end

  describe "#refresh_dns_servers" do
    before do
      r1 = DnsRecord.create_with_id(name: "test-pg-1", type: "A", ttl: 10, data: "1.2.3.4")
      r2 = DnsRecord.create_with_id(name: "test-pg-2", type: "A", ttl: 10, data: "5.6.7.8")
      r3 = DnsRecord.create_with_id(name: "test-pg-3", type: "A", ttl: 10, data: "9.10.11.12", tombstoned: true)

      dns_zone.add_record(r1)
      dns_zone.add_record(r2)
      dns_zone.add_record(r3)

      DB["INSERT INTO seen_dns_records_by_dns_servers(dns_record_id, dns_server_id) VALUES('#{r1.id}', '#{dns_server.id}')"].insert
    end

    it "does not push anything if there is no unseen records" do
      DB["INSERT INTO seen_dns_records_by_dns_servers SELECT id, '#{dns_server.id}' FROM dns_record"].insert

      expect(sshable).not_to receive(:cmd)
      expect { nx.refresh_dns_servers }.to hop("wait")
    end

    it "gathers unseen records for each dns server and pushes them to dns servers" do
      expected_commands = <<COMMANDS
zone-abort postgres.ubicloud.com
zone-begin postgres.ubicloud.com
zone-set postgres.ubicloud.com test-pg-2 10 A 5.6.7.8
zone-unset postgres.ubicloud.com test-pg-3 10 A 9.10.11.12
zone-commit postgres.ubicloud.com
COMMANDS

      expect(sshable).to receive(:cmd).with("sudo -u knot knotc", stdin: expected_commands.chomp).and_return("OK\nOK\nOK\nOK\nOK")
      expect { nx.refresh_dns_servers }.to hop("wait")
    end

    it "ignores unimportant errors" do
      expect(sshable).to receive(:cmd).and_return("no active transaction\nOK\nsuch record already exists in zone\nno such record in zone found\nOK")
      expect { nx.refresh_dns_servers }.to hop("wait")
    end

    it "raises an exception for unexpected failures" do
      expect(sshable).to receive(:cmd).and_return("error in zone-abort\nOK\nOK\nOK\nOK")

      expect {
        nx.refresh_dns_servers
      }.to raise_error RuntimeError, "Rectify failed on #{dns_server}. Command: zone-abort postgres.ubicloud.com. Output: error in zone-abort"
    end
  end
end
