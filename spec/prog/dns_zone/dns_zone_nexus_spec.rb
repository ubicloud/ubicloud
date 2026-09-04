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

    it "naps if there is nothing to do" do
      expect { nx.wait }.to nap(10)
    end

    it "hops to configure when the configure semaphore is set" do
      nx.incr_configure
      expect { nx.wait }.to hop("configure")
      expect(Semaphore.where(strand_id: dns_zone.id, name: "configure")).to be_empty
    end
  end

  describe "#configure" do
    it "queues each dns server vm and hops to wait_configure" do
      vm
      expect { nx.configure }.to hop("wait_configure")
      expect(nx.configure_queue).to eq [{"subject_id" => vm.id, "dns_server_id" => dns_server.id}]
    end
  end

  describe "#wait_configure" do
    it "buds configure for one vm at a time and hops to wait when the queue drains" do
      vm
      other_vm = create_vm(project_id: prj.id, name: "dns-vm-2")
      Sshable.create_with_id(other_vm, unix_user: "root", host: "test-host-2")
      dns_server.add_vm(other_vm)
      expect { nx.configure }.to hop("wait_configure")

      expect { nx.wait_configure }.to nap(5)
      children = Strand.where(parent_id: dns_zone.id).all
      expect(children.map(&:prog)).to eq ["DnsZone::SetupDnsServerVm"]
      expect(children.map(&:label)).to eq ["configure"]
      first_frame = children.first.stack.first
      expect([vm.id, other_vm.id]).to include first_frame["subject_id"]
      expect(first_frame["dns_server_id"]).to eq dns_server.id

      expect { nx.wait_configure }.to nap(10)
      expect(Strand.where(parent_id: dns_zone.id).count).to eq 1

      children.first.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}))
      expect { nx.wait_configure }.to nap(5)
      children = Strand.where(parent_id: dns_zone.id).all
      expect(children.map { it.stack.first["subject_id"] }).to eq [vm.id, other_vm.id] - [first_frame["subject_id"]]

      children.first.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}))
      expect { nx.wait_configure }.to hop("wait")
      expect(Strand.where(parent_id: dns_zone.id)).to be_empty
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
