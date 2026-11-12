# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::DnsZone::DnsZoneNexus do
  subject(:nx) { described_class.new(dns_zone.strand) }

  let(:prj) { Project.create(name: "test-prj") }
  let(:dns_zone) {
    dz = DnsZone.create(project_id: prj.id, name: "postgres.ubicloud.com")
    Strand.create_with_id(dz, prog: "DnsZone::DnsZoneNexus", label: "wait")
    dz.add_dns_server(dns_server)
    dz
  }
  let(:dns_server) { DnsServer.create(name: "ns.ubicloud.com") }
  let(:vm) {
    v = create_vm(project_id: prj.id, name: "dns-vm")
    Sshable.create_with_id(v, unix_user: "root", host: "test-host")
    dns_server.add_vm(v)
    v
  }

  describe "#wait" do
    it "hops to refresh_dns_servers if refresh_dns_servers semaphore is set" do
      nx.incr_refresh_dns_servers
      expect { nx.wait }.to hop("refresh_dns_servers")
    end

    it "hops to purge_obsolete_records if last purge happened more than 1 hour ago" do
      dns_zone.update(last_purged_at: Time.now - 60 * 60 * 2)
      expect { nx.wait }.to hop("purge_obsolete_records")
    end

    it "hops to rectify_apex if rectify_apex semaphore is set" do
      nx.incr_rectify_apex
      expect { nx.wait }.to hop("rectify_apex")
    end

    it "naps if there is nothing to do" do
      expect { nx.wait }.to nap(10)
    end
  end

  describe "#rectify_apex" do
    let(:read_stdin) { "zone-read postgres.ubicloud.com @ NS\nzone-read postgres.ubicloud.com @ SOA" }

    def default_apex(server_name)
      "postgres.ubicloud.com. 3600 NS #{server_name}.\npostgres.ubicloud.com. 3600 SOA ns.postgres.ubicloud.com. postgres.ubicloud.com. 41 86400 7200 1209600 3600\n"
    end

    def update_stdin(server_name)
      [
        "zone-abort postgres.ubicloud.com",
        "zone-begin postgres.ubicloud.com",
        "zone-unset postgres.ubicloud.com @ NS #{server_name}.",
        "zone-set postgres.ubicloud.com @ 3600 NS ns1.example.net.",
        "zone-set postgres.ubicloud.com @ 3600 SOA ns1.example.net. postgres.ubicloud.com. 42 86400 7200 1209600 3600",
        "zone-commit postgres.ubicloud.com",
      ].join("\n")
    end

    before do
      dns_zone.update(apex_nameservers: ["ns1.example.net"])
      nx.incr_rectify_apex
    end

    it "rectifies the apex on every VM of every server of the zone" do
      vm
      other_server = DnsServer.create(name: "ns2.ubicloud.com")
      dns_zone.add_dns_server(other_server)
      other_vm = create_vm(project_id: prj.id, name: "dns-vm-2")
      Sshable.create_with_id(other_vm, unix_user: "root", host: "test-host-2")
      other_server.add_vm(other_vm)

      nx.dns_zone.dns_servers.each do |server|
        server.vms.each do |target|
          expect(target.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: read_stdin, log: false).and_return(default_apex(server.name))
          expect(target.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: update_stdin(server.name)).and_return("OK\n" * 6)
        end
      end
      expect(nx.dns_zone.dns_servers.flat_map(&:vms).map(&:id)).to contain_exactly(vm.id, other_vm.id)

      expect { nx.rectify_apex }.to hop("wait")
      expect(Semaphore.where(strand_id: dns_zone.id, name: "rectify_apex")).to be_empty
    end

    it "keeps the request when a VM fails, so the strand retries" do
      vm
      expect(nx.dns_zone.dns_servers.first.vms.first.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: read_stdin, log: false).and_raise(Errno::ECONNREFUSED)

      expect { DB.transaction(savepoint: true) { nx.rectify_apex } }.to raise_error(Errno::ECONNREFUSED)
      expect(Semaphore.where(strand_id: dns_zone.id, name: "rectify_apex").count).to eq 1
    end
  end

  describe "#refresh_dns_servers" do
    before do
      vm
      r1 = DnsRecord.create(name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r2 = DnsRecord.create(name: "test-pg-2.postgres.ubicloud.com.", type: "A", ttl: 10, data: "5.6.7.8", dns_zone_id: dns_zone.id)
      r3 = DnsRecord.create(name: "test-pg-3.postgres.ubicloud.com.", type: "A", ttl: 10, data: "9.10.11.12", tombstoned: true, dns_zone_id: dns_zone.id)

      dns_zone.add_record(r1)
      dns_zone.add_record(r2)
      dns_zone.add_record(r3)

      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r1.id, dns_server_id: dns_server.id)
    end

    let(:sshable) { nx.dns_zone.dns_servers.first.vms.first.sshable }

    it "does not push anything if there is no unseen records" do
      DB[:seen_dns_records_by_dns_servers].insert(DB[:dns_record].select(:id, dns_server.id))

      expect(sshable).not_to receive(:_cmd)
      expect { nx.refresh_dns_servers }.to hop("purge_obsolete_records")
    end

    it "gathers unseen records for each dns server and pushes them to dns servers" do
      expected_commands = <<COMMANDS
zone-abort postgres.ubicloud.com
zone-begin postgres.ubicloud.com
zone-set postgres.ubicloud.com test-pg-2.postgres.ubicloud.com. 10 A 5.6.7.8
zone-unset postgres.ubicloud.com test-pg-3.postgres.ubicloud.com. 10 A 9.10.11.12
zone-commit postgres.ubicloud.com
COMMANDS

      expect(sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: expected_commands.chomp).and_return("OK\nOK\nOK\nOK\nOK")
      DnsRecord.where(data: "5.6.7.8").update(created_at: Time.now - 60)
      expect { nx.refresh_dns_servers }.to hop("purge_obsolete_records")
    end

    it "ignores unimportant errors" do
      expect(sshable).to receive(:_cmd).and_return("no active transaction\nOK\nno such record in zone found\nsuch record already exists in zone\nOK\n")
      expect { nx.refresh_dns_servers }.to hop("purge_obsolete_records")
    end

    it "raises an exception for unexpected failures" do
      expect(sshable).to receive(:_cmd).and_return("error in zone-abort\nOK\nOK\nOK\nOK")

      expect {
        nx.refresh_dns_servers
      }.to raise_error RuntimeError, "Rectify failed on #{dns_server}. Command: zone-abort postgres.ubicloud.com. Output: error in zone-abort"
    end
  end

  describe "#purge_obsolete_records" do
    it "deletes obsoleted records, seen or unseen" do
      r1 = DnsRecord.create(created_at: Time.now - 1, name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r2 = DnsRecord.create(created_at: Time.now, name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r3 = DnsRecord.create(created_at: Time.now + 1, name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)

      dns_zone.add_record(r1)
      dns_zone.add_record(r2)
      dns_zone.add_record(r3)

      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r1.id, dns_server_id: dns_server.id)
      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r3.id, dns_server_id: dns_server.id)

      expect { nx.purge_obsolete_records }.to hop("wait")
      expect(dns_zone.reload.records.count).to eq(1)
      expect(DB[:seen_dns_records_by_dns_servers].all.count).to eq(1)
    end

    it "deletes seen tombstoned records" do
      r1 = DnsRecord.create(name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r2 = DnsRecord.create(name: "test-pg-2.postgres.ubicloud.com.", type: "A", ttl: 10, data: "5.6.7.8", tombstoned: true, dns_zone_id: dns_zone.id)
      r3 = DnsRecord.create(name: "test-pg-3.postgres.ubicloud.com.", type: "A", ttl: 10, data: "9.10.11.12", tombstoned: true, dns_zone_id: dns_zone.id)

      dns_zone.add_record(r1)
      dns_zone.add_record(r2)
      dns_zone.add_record(r3)

      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r1.id, dns_server_id: dns_server.id)
      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r2.id, dns_server_id: dns_server.id)

      expect { nx.purge_obsolete_records }.to hop("wait")
      expect(dns_zone.reload.records.count).to eq(2)
      expect(DB[:seen_dns_records_by_dns_servers].all.count).to eq(1)
    end
  end
end
