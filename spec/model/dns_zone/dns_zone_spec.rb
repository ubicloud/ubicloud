# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DnsZone do
  subject(:dns_zone) {
    described_class.create(
      project_id:,
      name: "example.com",
    )
  }

  let(:project_id) { Project.create(name: "test").id }

  context "when inserting new record" do
    it "creates record in database" do
      dns_zone.insert_record(record_name: "test.example.com", type: "A", ttl: 10, data: "1.2.3.4")

      expect(dns_zone.records.count).to eq(1)
    end
  end

  context "when deleting a record" do
    before do
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.example.com.", type: "A", ttl: 10, data: "1.2.3.4")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.example.com.", type: "A", ttl: 10, data: "5.6.7.8")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.example.com.", type: "TXT", ttl: 10, data: "5.6.7.8")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test2.example.com.", type: "A", ttl: 10, data: "5.6.7.8")
    end

    it "raises error if data is passed but type is not" do
      expect {
        dns_zone.delete_record(record_name: "test1.example.com", data: "1.2.3.4")
      }.to raise_error RuntimeError, "Type needs to be specified if data is specified!"
    end

    it "deletes all matching records from database when only record_name is passed" do
      dns_zone.delete_record(record_name: "test1.example.com")
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(3)
    end

    it "does not insert new tombstoned records for existing tombstoned records" do
      4.times do
        dns_zone.delete_record(record_name: "test1.example.com")
      end
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(12)
    end

    it "deletes all matching records from database when record_name and type are passed" do
      dns_zone.delete_record(record_name: "test1.example.com", type: "A")
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(2)
    end

    it "deletes all matching records from database when record_name, type and data are passed" do
      dns_zone.delete_record(record_name: "test1.example.com", type: "A", data: "1.2.3.4")
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(1)
    end

    it "creates only one tombstone per unique record when duplicates exist" do
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.example.com.", type: "A", ttl: 10, data: "1.2.3.4")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.example.com.", type: "A", ttl: 10, data: "1.2.3.4")

      dns_zone.delete_record(record_name: "test1.example.com", type: "A", data: "1.2.3.4")
      tombstone_records = dns_zone.records_dataset.where(name: "test1.example.com.", type: "A", data: "1.2.3.4", tombstoned: true)
      expect(tombstone_records.count).to eq(1)
    end
  end

  it "returns record_name with dot" do
    expect(dns_zone.add_dot_if_missing("pg-name.postgres.ubicloud.com")).to eq("pg-name.postgres.ubicloud.com.")
    expect(dns_zone.add_dot_if_missing("pg-name.postgres.ubicloud.com.")).to eq("pg-name.postgres.ubicloud.com.")
  end

  describe "apex" do
    let(:dz) { described_class.create(project_id:, name: "c0.example.com") }
    let(:ds) { DnsServer.create(name: "c0.example.com") }
    let(:vm) {
      vm = create_vm(project_id:, name: "dns-vm")
      Sshable.create_with_id(vm, host: "dns.test")
      vm
    }
    let(:read_stdin) { "zone-read c0.example.com @ NS\nzone-read c0.example.com @ SOA" }
    let(:default_apex) {
      <<~OUT
        c0.example.com. 3600 NS c0.example.com.
        c0.example.com. 3600 SOA ns.c0.example.com. c0.example.com. 41 86400 7200 1209600 3600
      OUT
    }

    describe "#validate" do
      it "accepts unset and well-formed apex values" do
        expect(dz).to be_valid
        dz.set(nameservers: ["ns1-c0.example.net", "NS2-c0.example.net."], soa_email: "dns.admin+pg@example.org")
        expect(dz).to be_valid
      end

      it "rejects an empty nameserver list" do
        dz.nameservers = []
        expect(dz).not_to be_valid
        expect(dz.errors[:nameservers]).to eq ["must not be empty"]
      end

      it "rejects nameservers that are not hostnames" do
        dz.nameservers = ["ns1.example.net", "ns2.example.net\nzone-purge c0.example.com"]
        expect(dz).not_to be_valid
        expect(dz.errors[:nameservers]).to eq ["must be hostnames"]
      end

      it "rejects a malformed SOA email" do
        dz.soa_email = "hostmaster example.org"
        expect(dz).not_to be_valid
        expect(dz.errors[:soa_email]).to eq ["must be an email address"]
      end
    end

    describe "#update_apex" do
      before do
        Strand.create_with_id(ds, prog: "DnsZone::DnsServerNexus", label: "wait")
        dz.add_dns_server(ds)
      end

      def configure_requests
        Semaphore.where(strand_id: ds.id, name: "configure").count
      end

      it "keeps the default apex when nothing is configured" do
        dz.update_apex(nameservers: nil, soa_email: nil)
        expect(dz.reload).to have_attributes(nameservers: nil, soa_email: nil, revert_apex: false)
        expect(configure_requests).to eq 0
      end

      it "stores the apex and requests a reconfiguration only when it changes" do
        allow(Clog).to receive(:emit).and_call_original
        expect(Clog).to receive(:emit).with("DNS zone apex changed", {dns_zone_apex: {ubid: dz.ubid, name: "c0.example.com", nameservers: ["ns1-c0.example.com", "ns2-c0.example.com"], soa_email: "hostmaster@example.com", revert_apex: false}}).and_call_original
        dz.update_apex(nameservers: ["ns1-c0.example.com", "ns2-c0.example.com"], soa_email: "hostmaster@example.com")
        expect(dz.reload).to have_attributes(nameservers: ["ns1-c0.example.com", "ns2-c0.example.com"], soa_email: "hostmaster@example.com")
        expect(configure_requests).to eq 1

        dz.update_apex(nameservers: ["ns1-c0.example.com", "ns2-c0.example.com"], soa_email: "hostmaster@example.com")
        expect(configure_requests).to eq 1

        dz.update_apex(nameservers: ["ns1-c0.example.com"], soa_email: "hostmaster@example.com")
        expect(dz.reload.nameservers).to eq ["ns1-c0.example.com"]
        expect(configure_requests).to eq 2
      end

      it "marks a revert when the values are removed, and retries it until it finishes" do
        dz.update_apex(nameservers: ["ns1-c0.example.com"], soa_email: "hostmaster@example.com")
        dz.update_apex(nameservers: ["ns1-c0.example.com"], soa_email: nil)
        expect(dz.reload).to have_attributes(soa_email: nil, revert_apex: false)

        allow(Clog).to receive(:emit).and_call_original
        expect(Clog).to receive(:emit).with("DNS zone apex changed", {dns_zone_apex: {ubid: dz.ubid, name: "c0.example.com", nameservers: nil, soa_email: nil, revert_apex: true}}).and_call_original
        dz.update_apex(nameservers: nil, soa_email: nil)
        expect(dz.reload).to have_attributes(nameservers: nil, revert_apex: true)
        expect(configure_requests).to eq 3

        dz.update_apex(nameservers: nil, soa_email: nil)
        expect(configure_requests).to eq 4

        dz.update(revert_apex: false)
        dz.update_apex(nameservers: nil, soa_email: nil)
        expect(configure_requests).to eq 4
      end

      it "drops a pending revert when values are configured again" do
        dz.update(revert_apex: true)
        dz.update_apex(nameservers: nil, soa_email: "dns@example.com")
        expect(dz.reload).to have_attributes(soa_email: "dns@example.com", revert_apex: false)
      end

      it "rejects invalid apex values" do
        expect { dz.update_apex(nameservers: ["not a hostname"], soa_email: nil) }.to raise_error Sequel::ValidationFailed, "nameservers must be hostnames"
      end
    end

    describe "apex values" do
      it "defaults to the DNS server name and the historical SOA names" do
        expect(dz.custom_apex?).to be false
        expect(dz.apex_nameservers(ds)).to eq ["c0.example.com."]
        expect(dz.soa_mname).to eq "ns.c0.example.com."
        expect(dz.soa_rname).to eq "c0.example.com."
      end

      it "uses the configured nameservers, the first one as SOA MNAME" do
        dz.update(nameservers: ["NS1-c0.example.net", "ns2-c0.example.net."])
        expect(dz.custom_apex?).to be true
        expect(dz.apex_nameservers(ds)).to eq ["ns1-c0.example.net.", "ns2-c0.example.net."]
        expect(dz.soa_mname).to eq "ns1-c0.example.net."
        expect(dz.soa_rname).to eq "c0.example.com."
      end

      it "turns the SOA email into an RNAME, escaping dots in the local part" do
        dz.update(soa_email: "DNS.Admin@Example.org")
        expect(dz.custom_apex?).to be true
        expect(dz.apex_nameservers(ds)).to eq ["c0.example.com."]
        expect(dz.soa_rname).to eq "dns\\.admin.example.org."
      end
    end

    describe "#apex_commands" do
      before { dz.update(nameservers: ["ns1-c0.example.net", "ns2-c0.example.net"], soa_email: "dns.admin@example.org") }

      it "replaces the NS set and rewrites the SOA with the next serial" do
        expect(dz.apex_commands(ds, default_apex)).to eq [
          "zone-unset c0.example.com @ NS c0.example.com.",
          "zone-set c0.example.com @ 3600 NS ns1-c0.example.net.",
          "zone-set c0.example.com @ 3600 NS ns2-c0.example.net.",
          "zone-set c0.example.com @ 3600 SOA ns1-c0.example.net. dns\\\\.admin.example.org. 42 86400 7200 1209600 3600",
        ]
      end

      it "returns nothing when the apex already matches" do
        current = <<~OUT
          c0.example.com. 3600 NS ns2-c0.example.net.
          c0.example.com. 3600 NS ns1-c0.example.net.
          c0.example.com. 3600 SOA ns1-c0.example.net. dns\\.admin.example.org. 42 86400 7200 1209600 3600
        OUT
        expect(dz.apex_commands(ds, current)).to be_empty
      end

      it "only touches what differs" do
        current = <<~OUT
          c0.example.com. 3600 NS ns1-c0.example.net.
          c0.example.com. 3600 SOA ns1-c0.example.net. dns\\.admin.example.org. 42 86400 7200 1209600 30
        OUT
        expect(dz.apex_commands(ds, current)).to eq ["zone-set c0.example.com @ 3600 NS ns2-c0.example.net."]
      end

      it "reads the zone-prefixed output of older knotc versions" do
        current = <<~OUT
          [c0.example.com.] c0.example.com. 3600 NS ns2-c0.example.net.
          [c0.example.com.] c0.example.com. 3600 NS ns1-c0.example.net.
          [c0.example.com.] c0.example.com. 3600 SOA ns1-c0.example.net. dns\\.admin.example.org. 42 86400 7200 1209600 3600
        OUT
        expect(dz.apex_commands(ds, current)).to be_empty
        expect(dz.apex_commands(ds, default_apex.gsub(/^/, "[c0.example.com.] "))).to eq dz.apex_commands(ds, default_apex)
      end

      it "ignores lines for other owners and knotc errors" do
        current = "error: (no such record in zone found)\nwww.c0.example.com. 60 A 192.0.2.1\n#{default_apex}"
        expect(dz.apex_commands(ds, current).length).to eq 4
      end

      it "fails when the zone has no SOA" do
        expect { dz.apex_commands(ds, "c0.example.com. 3600 NS c0.example.com.\n") }.to raise_error RuntimeError, "Zone c0.example.com has no SOA record"
      end
    end

    describe "#rectify_apex" do
      it "does not touch the VM when the apex is not configured" do
        expect(vm.sshable).not_to receive(:_cmd)
        dz.rectify_apex(ds, vm)
      end

      it "writes the default apex back for a pending revert" do
        dz.update(revert_apex: true)
        expect(dz.manages_apex?).to be true
        current = "c0.example.com. 3600 NS ns1-c0.example.net.\nc0.example.com. 3600 SOA ns1-c0.example.net. hostmaster.example.org. 42 86400 7200 1209600 3600\n"
        commands = [
          "zone-abort c0.example.com",
          "zone-begin c0.example.com",
          "zone-unset c0.example.com @ NS ns1-c0.example.net.",
          "zone-set c0.example.com @ 3600 NS c0.example.com.",
          "zone-set c0.example.com @ 3600 SOA ns.c0.example.com. c0.example.com. 43 86400 7200 1209600 3600",
          "zone-commit c0.example.com",
        ]
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: read_stdin, log: false).and_return(current)
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands.join("\n")).and_return("OK\n" * 6)
        dz.rectify_apex(ds, vm)
      end

      it "does nothing beyond reading when the apex already matches" do
        dz.update(nameservers: ["c0.example.com"])
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: read_stdin, log: false).and_return(default_apex.sub("ns.c0", "c0"))
        dz.rectify_apex(ds, vm)
      end

      it "applies the changes in one transaction" do
        dz.update(nameservers: ["ns1-c0.example.net"])
        commands = [
          "zone-abort c0.example.com",
          "zone-begin c0.example.com",
          "zone-unset c0.example.com @ NS c0.example.com.",
          "zone-set c0.example.com @ 3600 NS ns1-c0.example.net.",
          "zone-set c0.example.com @ 3600 SOA ns1-c0.example.net. c0.example.com. 42 86400 7200 1209600 3600",
          "zone-commit c0.example.com",
        ]
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: read_stdin, log: false).and_return(default_apex)
        expect(Clog).to receive(:emit).with("Updating DNS zone apex", {dns_zone: "c0.example.com", vm_ubid: vm.ubid, commands:}).and_call_original
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands.join("\n")).and_return("error: (no active transaction)\nOK\nOK\nOK\nOK\nOK")
        dz.rectify_apex(ds, vm)
      end

      it "raises when knotc reports an error" do
        dz.update(soa_email: "hostmaster@example.org")
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: read_stdin, log: false).and_return(default_apex)
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: /zone-set c0.example.com @ 3600 SOA ns.c0.example.com. hostmaster.example.org. 42 /).and_return("OK\nOK\nOK\nerror: (semantic check) [c0.example.com]")
        expect { dz.rectify_apex(ds, vm) }.to raise_error RuntimeError, "Updating apex of c0.example.com failed on #{vm.ubid}. Command: zone-commit c0.example.com. Output: error: (semantic check) [c0.example.com]"
      end
    end
  end
end
