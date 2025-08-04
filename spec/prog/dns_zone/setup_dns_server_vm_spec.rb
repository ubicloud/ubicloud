# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::DnsZone::SetupDnsServerVm do
  subject(:prog) {
    st = described_class.assemble(ds.id)
    described_class.new(st)
  }

  before do
    allow(Config).to receive(:dns_service_project_id).and_return(project.id)
  end

  let(:ds) { DnsServer.create(name: "toruk") }
  let(:dzs) do
    build_zone = ->(name, neg_ttl) do
      dz = DnsZone.create(project_id: project.id, name: name, last_purged_at: Time.now, neg_ttl: neg_ttl)
      Strand.create(prog: "DnsZone::DnsZoneNexus", label: "wait") { it.id = dz.id }
      dz.add_dns_server ds
      3.times { dz.insert_record(record_name: "#{SecureRandom.alphanumeric(6)}.#{dz.name}", type: "A", ttl: 10, data: IPAddr.new(rand(2**32), Socket::AF_INET).to_s) }
      dz
    end

    (1..2).map { |i| build_zone.call("zone#{i}.domain.io", 3600) } << build_zone.call("k8s.ubicloud.com", 15)
  end
  let(:project) { Project.create(name: "ubicloud-dns") }

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(SecureRandom.uuid)
      }.to raise_error RuntimeError, "No existing Dns Server"

      expect {
        described_class.assemble(ds.id, name: "InVaLidNAME")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(ds.id, location_id: nil)
      }.to raise_error RuntimeError, "No existing Location"

      expect(described_class.assemble(ds.id)).to be_a Strand

      expect(Vm.count).to eq 1
      expect(Vm.first.unix_user).to eq "ubi"
    end

    it "errors out if the dns service project id is not put into config properly" do
      expect(Config).to receive(:dns_service_project_id).and_return(nil)
      expect {
        described_class.assemble(ds.id)
      }.to raise_error RuntimeError, "No existing Project"
    end

    it "errors out if the DNS Server VMs are not in sync" do
      expect(described_class).to receive(:vms_in_sync?).and_return(false)
      expect {
        described_class.assemble(ds.id)
      }.to raise_error RuntimeError, "Existing DNS Server VMs are not in sync, try again later"
    end
  end

  describe ".vms_in_sync?" do
    let(:vms) {
      vms = [create_vm, create_vm]
      vms[0].sshable = Sshable.new
      vms[1].sshable = Sshable.new
      vms
    }

    it "returns true if no VMs are given" do
      expect(described_class.vms_in_sync?(nil)).to be true
      expect(described_class.vms_in_sync?([])).to be true
    end

    it "returns false if the command outputs are do not match" do
      expect(vms[0].sshable).to receive(:cmd).and_return "foo"
      expect(vms[1].sshable).to receive(:cmd).and_return "bar"
      expect(described_class.vms_in_sync?(vms)).to be false
    end

    it "returns true if the dns records match, irrespective of order" do
      expect(vms[0].sshable).to receive(:cmd).and_return <<-DNS
[zone1.] name1.zone1. 10 A 127.1.2.3
[zone2.] zone2. 3600 NS zone2.
[zone2.] zone2. 3600 SOA ns.zone2. zone2. 38 86400 7200 1209600 3600
      DNS
      expect(vms[1].sshable).to receive(:cmd).and_return <<-DNS
[zone2.] zone2. 3600 SOA ns.zone2. zone2. 38 86400 7200 1209600 3600
[zone1.] name1.zone1. 10 A 127.1.2.3
[zone2.] zone2. 3600 NS zone2.
      DNS
      expect(described_class.vms_in_sync?(vms)).to be true
    end

    it "returns true even if the serial numbers of SOA records are different" do
      expect(vms[0].sshable).to receive(:cmd).and_return <<-DNS
[erentest2.ibicloud.com.] erentest2.ibicloud.com. 3600 SOA ns.erentest2.ibicloud.com. erentest2.ibicloud.com. 38 86400 7200 1209600 3600
      DNS
      expect(vms[1].sshable).to receive(:cmd).and_return <<-DNS
[erentest2.ibicloud.com.] erentest2.ibicloud.com. 3600 SOA ns.erentest2.ibicloud.com. erentest2.ibicloud.com. 56 86400 7200 1209600 3600
      DNS
      expect(described_class.vms_in_sync?(vms)).to be true
    end
  end

  describe "#start" do
    it "naps if vm is not ready" do
      expect(prog.vm.strand.label).not_to be "wait"
      expect { prog.start }.to nap(5)
    end

    it "hops to prepare when VM is ready" do
      prog.vm.strand.update(label: "wait")
      expect(prog.strand.stack.first["deadline_at"]).to be_nil
      expect { prog.start }.to hop("prepare")
      expect(prog.strand.stack.first["deadline_at"]).not_to be_nil
    end
  end

  describe "#prepare" do
    it "runs some commands to prepare vm for knot installation and restarts" do
      prog.vm.strand.update(label: "wait")

      expect(prog.sshable).to receive(:cmd).with(/sudo ln -sf \/run\/systemd\/resolve\/resolv.conf \/etc\/resolv.conf[\S\s]*sudo systemctl reboot/)

      expect { prog.prepare }.to hop("setup_knot")
    end
  end

  describe "#setup_knot" do
    it "waits until the vm is ready to accept commands again" do
      expect(prog.sshable).to receive(:cmd).and_raise(IOError)
      expect { prog.setup_knot }.to nap(5)
    end

    it "runs some commands to install and configure knot on the vm" do
      expect(prog.sshable).to receive(:cmd).with("true").and_return(true)

      zone_conf = <<-CONF
  - domain: "zone1.domain.io."
  - domain: "zone2.domain.io."
      CONF

      expect(prog.ds).to receive(:dns_zones).and_return(dzs) # To ensure the order
      expect(prog.sshable).to receive(:cmd).with(/sudo apt-get -y install knot/)
      expect(prog.sshable).to receive(:cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: /#{zone_conf}/)

      expect { prog.setup_knot }.to hop("sync_zones")
    end
  end

  describe "#sync_zones" do
    it "naps if any pending dns refresh semaphore is set" do
      dzs.first.incr_refresh_dns_servers
      expect { prog.sync_zones }.to nap(5)
    end

    it "writes knot zone template for each zone" do
      expect(dzs).to all(receive(:refresh_dns_servers_set?).and_return(false))

      f1 = <<-CONF
zone1.domain.io.          3600    SOA     ns.zone1.domain.io. zone1.domain.io. 37 86400 7200 1209600 3600
zone1.domain.io.          3600    NS      toruk.
      CONF
      f2 = <<-CONF
zone2.domain.io.          3600    SOA     ns.zone2.domain.io. zone2.domain.io. 37 86400 7200 1209600 3600
zone2.domain.io.          3600    NS      toruk.
      CONF
      f3 = <<-CONF
k8s.ubicloud.com.          3600    SOA     ns.k8s.ubicloud.com. k8s.ubicloud.com. 37 86400 7200 1209600 15
k8s.ubicloud.com.          3600    NS      toruk.
      CONF

      expect(prog.sshable).to receive(:cmd).with("sudo -u knot tee /var/lib/knot/zone1.domain.io.zone > /dev/null", stdin: f1)
      expect(prog.sshable).to receive(:cmd).with("sudo -u knot tee /var/lib/knot/zone2.domain.io.zone > /dev/null", stdin: f2)
      expect(prog.sshable).to receive(:cmd).with("sudo -u knot tee /var/lib/knot/k8s.ubicloud.com.zone > /dev/null", stdin: f3)

      expect(prog.sshable).to receive(:cmd).with("sudo systemctl restart knot")
      expect(dzs).to all(receive(:purge_obsolete_records))

      knotc_input = <<-INPUT
zone-abort zone1.domain.io
zone-begin zone1.domain.io
zone-set zone1.domain.io #{dzs[0].records.first.name} 10 A #{dzs[0].records.first.data}
[\\S\\s]*
zone-commit zone1.domain.io
zone-flush zone1.domain.io
zone-abort zone2.domain.io
zone-begin zone2.domain.io
zone-set zone2.domain.io #{dzs[1].records.first.name} 10 A #{dzs[1].records.first.data}
[\\S\\s]*
zone-commit zone2.domain.io
zone-flush zone2.domain.io
zone-abort k8s.ubicloud.com
zone-begin k8s.ubicloud.com
zone-set k8s.ubicloud.com #{dzs[2].records.first.name} 10 A #{dzs[2].records.first.data}
[\\S\\s]*
zone-commit k8s.ubicloud.com
zone-flush k8s.ubicloud.com
      INPUT
      expect(prog.sshable).to receive(:cmd).with("sudo -u knot knotc", stdin: /#{knotc_input.strip}/)

      expect(prog.ds).to receive(:dns_zones).at_least(:once).and_return(dzs) # To ensure the order
      expect { prog.sync_zones }.to hop("validate")
    end
  end

  describe "#validate" do
    it "validates the setup by checking outputs from different vms" do
      dummy_vm = instance_double(Vm, id: Vm.generate_uuid)
      dummy_sshable = instance_double(Sshable)
      expect(prog.ds).to receive(:vms).thrice.and_return([dummy_vm])
      expect(dummy_vm).to receive(:sshable).twice.and_return(dummy_sshable)

      expect(prog.vm.sshable).to receive(:cmd).twice
        .with("sudo -u knot knotc", stdin: "zone-read --")
        .and_return("line1\nline2")

      expect(dummy_sshable).to receive(:cmd)
        .with("sudo -u knot knotc", stdin: "zone-read --")
        .and_return("line1\nline3")

      # Different outputs
      expect { prog.validate }.to hop("sync_zones")

      expect(dummy_sshable).to receive(:cmd)
        .with("sudo -u knot knotc", stdin: "zone-read --")
        .and_return("line2\nline1")

      expect(prog.ds).to receive(:add_vm)

      # Same output but different order, doesn't matter
      expect { prog.validate }.to exit({"msg" => "created VM for DnsServer"})
    end

    it "doesn't add the same VM twice" do
      dummy_vm = instance_double(Vm, id: Vm.generate_uuid)
      dummy_sshable = instance_double(Sshable)
      expect(prog.ds).to receive(:vms).twice.and_return([dummy_vm, prog.vm])
      expect(dummy_vm).to receive(:sshable).and_return(dummy_sshable)

      expect(prog.vm.sshable).to receive(:cmd).at_least(:once).and_return("l1\nl2")
      expect(dummy_sshable).to receive(:cmd).and_return("l1\nl2")

      expect(prog.ds).not_to receive(:add_vm)

      expect { prog.validate }.to exit({"msg" => "created VM for DnsServer"})
    end
  end
end
