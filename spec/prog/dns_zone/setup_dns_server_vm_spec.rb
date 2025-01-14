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

  let(:ds) { DnsServer.create_with_id(name: "toruk") }
  let(:dzs) do
    (1..2).map do |i|
      dz = DnsZone.create_with_id(project_id: project.id, name: "zone#{i}.domain.io", last_purged_at: Time.now)
      Strand.create(prog: "DnsZone::DnsZoneNexus", label: "wait") { _1.id = dz.id }

      dz.add_dns_server ds
      (1..3).map { SecureRandom.alphanumeric(6) }.each do |r|
        dz.insert_record(record_name: "#{r}.#{dz.name}", type: "A", ttl: 10, data: IPAddr.new(rand(2**32), Socket::AF_INET).to_s)
      end
      dz
    end
  end
  let(:project) { Project.create_with_id(name: "ubicloud-dns") }

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(SecureRandom.uuid)
      }.to raise_error RuntimeError, "No existing Dns Server"

      expect {
        described_class.assemble(ds.id, name: "InVaLidNAME")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

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
      expect(dzs[0]).to receive(:refresh_dns_servers_set?).and_return(false)
      expect(dzs[1]).to receive(:refresh_dns_servers_set?).and_return(false)
      f1 = <<-CONF
zone1.domain.io.          3600    SOA     ns.zone1.domain.io. zone1.domain.io. 37 86400 7200 1209600 3600
zone1.domain.io.          3600    NS      toruk.
      CONF
      f2 = <<-CONF
zone2.domain.io.          3600    SOA     ns.zone2.domain.io. zone2.domain.io. 37 86400 7200 1209600 3600
zone2.domain.io.          3600    NS      toruk.
      CONF
      expect(prog.sshable).to receive(:cmd).with("sudo -u knot tee /var/lib/knot/zone1.domain.io.zone > /dev/null", stdin: f1)
      expect(prog.sshable).to receive(:cmd).with("sudo -u knot tee /var/lib/knot/zone2.domain.io.zone > /dev/null", stdin: f2)

      expect(prog.sshable).to receive(:cmd).with("sudo systemctl restart knot")
      expect(dzs[0]).to receive(:purge_obsolete_records)
      expect(dzs[1]).to receive(:purge_obsolete_records)

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
