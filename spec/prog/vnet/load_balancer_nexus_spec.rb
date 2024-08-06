# frozen_string_literal: true

RSpec.describe Prog::Vnet::LoadBalancerNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    described_class.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 80)
  }
  let(:ps) {
    prj = Project.create_with_id(name: "test-prj").tap { _1.associate_with_project(_1) }
    Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
  }
  let(:dns_zone) {
    DnsZone.create_with_id(project_id: ps.projects.first.id, name: "lb.ubicloud.com")
  }

  before do
    allow(nx).to receive_messages(load_balancer: st.subject)
    allow(Config).to receive(:load_balancer_service_hostname).and_return("lb.ubicloud.com")
  end

  describe ".assemble" do
    it "fails if private subnet does not exist" do
      expect {
        described_class.assemble("0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "creates a new load balancer" do
      lb = described_class.assemble(ps.id, name: "test-lb2", src_port: 80, dst_port: 80).subject
      expect(LoadBalancer.count).to eq 2
      expect(lb.projects.first).to eq ps.projects.first
      expect(lb.hostname).to eq "test-lb2.#{ps.ubid[-5...]}.lb.ubicloud.com"
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_destroy state" do
      expect(nx.strand).to receive(:label).and_return("wait_destroy").at_least(:once)
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#wait" do
    it "naps for 5 seconds if nothing to do" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect { nx.wait }.to nap(5)
    end

    it "creates new health probe if needed" do
      vm = Prog::Vm::Nexus.assemble("pub-key", ps.projects.first.id, name: "test-vm1", private_subnet_id: ps.id).subject
      st.subject.add_vm(vm)
      expect { nx.wait }.to hop("create_new_health_probe")
    end

    it "hops to update vm load balancers" do
      expect(nx).to receive(:when_update_load_balancer_set?).and_yield
      expect { nx.wait }.to hop("update_vm_load_balancers")
    end

    it "rewrites dns records" do
      expect(nx).to receive(:when_rewrite_dns_records_set?).and_yield
      expect(nx).to receive(:rewrite_dns_records)
      expect(nx).to receive(:decr_rewrite_dns_records)
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect { nx.wait }.to nap(5)
    end

    it "creates new cert if needed" do
      expect { nx.wait }.to hop("create_new_cert")
    end
  end

  describe "#create_new_cert" do
    it "creates a new cert" do
      dns_zone = DnsZone.create_with_id(name: "test-dns-zone", project_id: nx.load_balancer.private_subnet.projects.first.id)
      allow(described_class).to receive(:dns_zone).and_return(dns_zone)
      expect { nx.create_new_cert }.to hop("wait_cert_provisioning")
      expect(Strand.where(prog: "Vnet::CertNexus").count).to eq 1
      expect(nx.load_balancer.certs.count).to eq 1
    end
  end

  describe "#wait_cert_provisioning" do
    it "naps for 60 seconds if need_certificates? is true" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(true)
      expect { nx.wait_cert_provisioning }.to nap(60)
    end

    it "hops to wait if need_certificates? is false" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect { nx.wait_cert_provisioning }.to hop("wait")
    end
  end

  describe "#create_new_health_probe" do
    it "creates health probes for all vms" do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub-key", ps.projects.first.id, name: "test-vm#{_1}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(_1) }
      expect { nx.create_new_health_probe }.to hop("wait")
      expect(Strand.where(prog: "Vnet::LoadBalancerHealthProbes").count).to eq 3
      expect(st.children_dataset.count).to eq 3
    end
  end

  describe "#update_vm_load_balancers" do
    it "updates load balancers for all vms" do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub-key", ps.projects.first.id, name: "test-vm#{_1}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(_1) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
      expect(st.children_dataset.count).to eq 3
    end
  end

  describe "#wait_update_vm_load_balancers" do
    before do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub-key", ps.projects.first.id, name: "test-vm#{_1}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(_1) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
    end

    it "naps for 1 second if not all children are done" do
      expect(nx).to receive(:reap)
      expect { nx.wait_update_vm_load_balancers }.to nap(1)
    end

    it "decrements update_load_balancer and hops to wait if all children are done" do
      st.children.map(&:destroy)
      expect(nx).to receive(:decr_update_load_balancer)
      expect { nx.wait_update_vm_load_balancers }.to hop("wait")
    end
  end

  describe "#destroy" do
    before do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub-key", ps.projects.first.id, name: "test-vm#{_1}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(_1) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
      st.children.map(&:destroy)
    end

    it "decrements destroy and destroys all children" do
      expect(nx).to receive(:decr_destroy)
      expect(st.children).to all(receive(:destroy))
      expect { nx.destroy }.to hop("wait_destroy")

      expect(Strand.where(prog: "Vnet::UpdateLoadBalancer").count).to eq 3
    end

    it "deletes the dns record" do
      expect(described_class).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(nx).to receive(:decr_destroy)
      expect(st.children).to all(receive(:destroy))
      expect { nx.destroy }.to hop("wait_destroy")
    end
  end

  describe "#rewrite_dns_records" do
    it "rewrites the dns records" do
      vms = [instance_double(Vm, ephemeral_net4: NetAddr::IPv4Net.parse("192.168.1.0"), ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(described_class).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "A", data: "192.168.1.0/32", ttl: 10)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "AAAA", data: "fd10:9b0b:6b4b:8fb0::2", ttl: 10)
      nx.rewrite_dns_records
    end

    it "does not rewrite dns records if no vms" do
      expect(described_class).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return([])
      expect(described_class).not_to receive(:dns_zone)
      nx.rewrite_dns_records
    end

    it "does not rewrite dns records if no dns zone" do
      vms = [instance_double(Vm, ephemeral_net4: NetAddr::IPv4Net.parse("192.168.1.0"), ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(DnsRecord).not_to receive(:create)
      nx.rewrite_dns_records
    end

    it "does not create dns record if ephemeral_net4 doesn't exist" do
      vms = [instance_double(Vm, ephemeral_net4: nil, ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(described_class).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(dns_zone).not_to receive(:insert_record).with(record_name: st.subject.hostname, type: "A", data: "192.168.1.0/32", ttl: 10)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "AAAA", data: "fd10:9b0b:6b4b:8fb0::2", ttl: 10)
      nx.rewrite_dns_records
    end
  end

  describe "#wait_destroy" do
    it "naps for 5 seconds if not all children are done" do
      expect(nx).to receive(:reap)
      expect(nx).to receive(:leaf?).and_return(false)

      expect { nx.wait_destroy }.to nap(5)
    end

    it "deletes the load balancer and pops" do
      expect(nx).to receive(:reap)
      expect(nx).to receive(:leaf?).and_return(true)
      expect(nx.load_balancer).to receive(:destroy)
      expect { nx.wait_destroy }.to exit({"msg" => "load balancer deleted"})
      expect(LoadBalancersVms.count).to eq 0
    end

    it "destroys the certificate if it exists" do
      cert = Prog::Vnet::CertNexus.assemble(st.subject.hostname, dns_zone.id).subject
      lb = st.subject
      lb.add_cert(cert)
      expect(lb.certs.count).to eq 1
      expect(nx).to receive(:reap)
      expect(nx).to receive(:leaf?).and_return(true)
      expect { nx.wait_destroy }.to exit({"msg" => "load balancer deleted"})
      expect(CertsLoadBalancers.count).to eq 0
      expect(cert.destroy_set?).to be true
    end
  end
end
