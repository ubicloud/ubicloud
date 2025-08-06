# frozen_string_literal: true

RSpec.describe Prog::Vnet::LoadBalancerNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    cert = Prog::Vnet::CertNexus.assemble("test-host-name", dns_zone.id).subject
    lb = described_class.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080, health_check_protocol: "https").subject
    lb.add_cert(cert)
    lb.strand
  }
  let(:ps) {
    prj = Project.create(name: "test-prj")
    Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
  }
  let(:dns_zone) {
    dz = DnsZone.create(project_id: ps.project_id, name: "lb.ubicloud.com")
    Strand.create_with_id(dz.id, prog: "DnsZone::DnsZoneNexus", label: "wait")
    dz
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
      lb = described_class.assemble(ps.id, name: "test-lb2", src_port: 80, dst_port: 8080).subject
      expect(LoadBalancer.count).to eq 2
      expect(lb.project).to eq ps.project
      expect(lb.hostname).to eq "test-lb2.#{ps.ubid[-5...]}.lb.ubicloud.com"
    end

    it "creates a new load balancer with custom hostname" do
      dz = DnsZone.create(project_id: ps.project_id, name: "custom.ubicloud.com")
      lb = described_class.assemble(ps.id, name: "test-lb2", src_port: 80, dst_port: 8080, custom_hostname_prefix: "test-custom-hostname", custom_hostname_dns_zone_id: dz.id).subject
      expect(LoadBalancer.count).to eq 2
      expect(lb.project).to eq ps.project
      expect(lb.hostname).to eq "test-custom-hostname.custom.ubicloud.com"
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

    it "hops to update vm load balancers" do
      expect(nx).to receive(:when_update_load_balancer_set?).and_yield
      expect { nx.wait }.to hop("update_vm_load_balancers")
    end

    it "rewrites dns records" do
      expect(nx).to receive(:when_rewrite_dns_records_set?).and_yield
      expect { nx.wait }.to hop("rewrite_dns_records")
    end

    it "creates new cert if needed" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(true)
      expect { nx.wait }.to hop("create_new_cert")
    end

    it "increments rewrite_dns_records if needed" do
      expect(nx).to receive(:need_to_rewrite_dns_records?).and_return(true)
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect(nx.load_balancer).to receive(:incr_rewrite_dns_records)
      expect { nx.wait }.to nap(5)
    end
  end

  describe "#create_new_cert" do
    it "creates a new cert" do
      dns_zone = DnsZone.create(name: "test-dns-zone", project_id: nx.load_balancer.private_subnet.project_id)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone)
      expect { nx.create_new_cert }.to hop("wait_cert_provisioning")
      expect(Strand.where(prog: "Vnet::CertNexus").count).to eq 2
      expect(nx.load_balancer.certs.count).to eq 2
    end

    it "creates a cert without dns zone in development" do
      expect(Config).to receive(:development?).and_return(true)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(nil)
      expect { nx.create_new_cert }.to hop("wait_cert_provisioning")
      expect(Strand.where(prog: "Vnet::CertNexus").count).to eq 2
      expect(nx.load_balancer.certs.count).to eq 2
    end
  end

  describe "#wait_cert_provisioning" do
    it "naps for 60 seconds if need_certificates? is true" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(true)
      expect { nx.wait_cert_provisioning }.to nap(60)
    end

    it "hops to wait_cert_broadcast if need_certificates? is false and refresh_cert is set" do
      vm = Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "testvm", private_subnet_id: ps.id).subject
      nx.load_balancer.add_vm(vm)
      nx.load_balancer.incr_refresh_cert
      expect(Strand.where(prog: "Vnet::CertServer", label: "put_certificate").count).to eq 1
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect { nx.wait_cert_provisioning }.to hop("wait_cert_broadcast")
      expect(Strand.where(prog: "Vnet::CertServer", label: "reshare_certificate").count).to eq 1
    end

    it "hops to wait need_certificates? and refresh_cert are false" do
      vm = Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "testvm", private_subnet_id: ps.id).subject
      nx.load_balancer.add_vm(vm)
      expect(Strand.where(prog: "Vnet::CertServer", label: "put_certificate").count).to eq 1
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect { nx.wait_cert_provisioning }.to hop("wait")
      expect(Strand.where(prog: "Vnet::CertServer", label: "reshare_certificate").count).to eq 0
    end
  end

  describe "#wait_cert_broadcast" do
    it "naps for 1 second if not all children are done" do
      vm = Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "testvm", private_subnet_id: ps.id).subject
      nx.load_balancer.add_vm(vm)
      expect(nx).to receive(:reap)
      expect { nx.wait_cert_broadcast }.to nap(1)
    end

    it "hops to wait if all children are done and no certs to remove" do
      expect(nx).to receive(:reap)
      active_cert = Prog::Vnet::CertNexus.assemble("active-cert", dns_zone.id).subject
      expect(nx.load_balancer).to receive(:active_cert).and_return(active_cert)
      expect { nx.wait_cert_broadcast }.to hop("wait")
    end

    it "removes certs if all children are done and there are certs to remove" do
      cert_to_remove = Prog::Vnet::CertNexus.assemble("cert-to-remove", dns_zone.id).subject
      cert_to_remove.update(created_at: Time.now - 60 * 60 * 24 * 30 * 4)
      active_cert = Prog::Vnet::CertNexus.assemble("active-cert", dns_zone.id).subject
      expect(nx.load_balancer).to receive(:active_cert).and_return(active_cert)
      nx.load_balancer.add_cert(cert_to_remove)
      nx.load_balancer.add_cert(active_cert)

      expect(nx).to receive(:reap)

      expect { nx.wait_cert_broadcast }.to hop("wait")
      expect(Semaphore[name: "destroy", strand_id: cert_to_remove.id]).not_to be_nil
      expect(nx.load_balancer.reload.certs.count).to eq 1
    end
  end

  describe "#update_vm_load_balancers" do
    it "updates load balancers for all vms" do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "test-vm#{it}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(it) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
      # Update progs are budded in update_vm_load_balancers
      expect(st.children_dataset.where(prog: "Vnet::UpdateLoadBalancerNode", label: "update_load_balancer").count).to eq 3
    end
  end

  describe "#wait_update_vm_load_balancers" do
    before do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "test-vm#{it}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(it) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
    end

    it "naps for 1 second if not all children are done" do
      Strand.create(parent_id: st.id, prog: "UpdateLoadBalancerNode", label: "start", stack: [{}], lease: Time.now + 10)
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
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "test-vm#{it}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(it) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
      st.children.map(&:destroy)
    end

    it "decrements destroy and destroys all children" do
      expect(nx).to receive(:decr_destroy)
      expect(st.children).to all(receive(:destroy))
      expect { nx.destroy }.to hop("wait_destroy")

      expect(Strand.where(prog: "Vnet::UpdateLoadBalancerNode").count).to eq 3
    end

    it "deletes the dns record" do
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
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
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "A", data: "192.168.1.0/32", ttl: 10)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "AAAA", data: "fd10:9b0b:6b4b:8fb0::2", ttl: 10)
      expect { nx.rewrite_dns_records }.to hop("wait")
    end

    it "does not rewrite dns records if no vms" do
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return([])
      expect(nx.load_balancer).not_to receive(:dns_zone)
      expect { nx.rewrite_dns_records }.to hop("wait")
    end

    it "does not rewrite dns records if no dns zone" do
      vms = [instance_double(Vm, ephemeral_net4: NetAddr::IPv4Net.parse("192.168.1.0"), ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(DnsRecord).not_to receive(:create)
      expect { nx.rewrite_dns_records }.to hop("wait")
    end

    it "does not create dns record if ephemeral_net4 doesn't exist" do
      vms = [instance_double(Vm, ephemeral_net4: nil, ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(dns_zone).not_to receive(:insert_record).with(record_name: st.subject.hostname, type: "A", data: "192.168.1.0/32", ttl: 10)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "AAAA", data: "fd10:9b0b:6b4b:8fb0::2", ttl: 10)
      expect { nx.rewrite_dns_records }.to hop("wait")
    end

    it "does not create ipv4 dns record if stack is ipv6" do
      nx.load_balancer.update(stack: "ipv6")
      vms = [instance_double(Vm, ephemeral_net4: nil, ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(dns_zone).not_to receive(:insert_record).with(record_name: st.subject.hostname, type: "A", data: "192.168.1.0/32", ttl: 10)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "AAAA", data: "fd10:9b0b:6b4b:8fb0::2", ttl: 10)
      expect { nx.rewrite_dns_records }.to hop("wait")
    end

    it "does not create ipv6 dns record if stack is ipv4" do
      nx.load_balancer.update(stack: "ipv4")
      vms = [instance_double(Vm, ephemeral_net4: NetAddr::IPv4Net.parse("192.168.1.0"), ephemeral_net6: nil)]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(dns_zone).to receive(:delete_record).with(record_name: st.subject.hostname)
      expect(dns_zone).to receive(:insert_record).with(record_name: st.subject.hostname, type: "A", data: "192.168.1.0/32", ttl: 10)
      expect(dns_zone).not_to receive(:insert_record).with(record_name: st.subject.hostname, type: "AAAA", data: "fd10:9b0b:6b4b:8fb0::2", ttl: 10)
      expect { nx.rewrite_dns_records }.to hop("wait")
    end
  end

  describe "#wait_destroy" do
    it "naps for 5 seconds if not all children are done" do
      Strand.create(parent_id: st.id, prog: "UpdateLoadBalancerNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_destroy }.to nap(5)
    end

    it "deletes the load balancer and pops" do
      expect(nx.load_balancer).to receive(:destroy)
      expect { nx.wait_destroy }.to exit({"msg" => "load balancer deleted"})
      expect(LoadBalancerVm.count).to eq 0
    end

    it "destroys the certificate if it exists" do
      cert = Prog::Vnet::CertNexus.assemble(st.subject.hostname, dns_zone.id).subject
      lb = st.subject
      lb.add_cert(cert)
      expect(lb.certs.count).to eq 2
      expect { nx.wait_destroy }.to exit({"msg" => "load balancer deleted"})
      expect(CertsLoadBalancers.count).to eq 0
      expect(cert.destroy_set?).to be true
    end
  end

  describe ".need_to_rewrite_dns_records?" do
    it "returns true if dns record is missing for ipv4" do
      vms = [instance_double(Vm, ephemeral_net4: NetAddr::IPv4Net.parse("192.168.1.0"), ephemeral_net6: nil)]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(nx.need_to_rewrite_dns_records?).to be true
    end

    it "returns true if dns record is missing for ipv6" do
      vms = [instance_double(Vm, ephemeral_net4: nil, ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(nx.need_to_rewrite_dns_records?).to be true
    end

    it "returns false if dns record is present for ipv4 and lb is not ipv6 enabled" do
      vms = [instance_double(Vm, ephemeral_net4: NetAddr::IPv4Net.parse("192.168.1.0"), ephemeral_net6: nil)]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(nx.load_balancer).to receive(:ipv6_enabled?).and_return(false)
      dr = DnsRecord.create(dns_zone_id: dns_zone.id, name: nx.load_balancer.hostname + ".", type: "A", ttl: 10, data: "192.168.1.0/32")
      expect(dns_zone).to receive(:records_dataset).and_return(DnsRecord.where(id: dr.id))
      expect(nx.need_to_rewrite_dns_records?).to be false
    end

    it "returns false if dns record is present for ipv6 and lb is not ipv4 enabled" do
      vms = [instance_double(Vm, ephemeral_net4: nil, ephemeral_net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fb0::"))]
      expect(nx.load_balancer).to receive(:vms_to_dns).and_return(vms)
      expect(nx.load_balancer).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(nx.load_balancer).to receive(:ipv4_enabled?).and_return(false)
      dr = DnsRecord.create(dns_zone_id: dns_zone.id, name: nx.load_balancer.hostname + ".", type: "AAAA", ttl: 10, data: "fd10:9b0b:6b4b:8fb0::2")
      expect(dns_zone).to receive(:records_dataset).and_return(DnsRecord.where(id: dr.id))
      expect(nx.need_to_rewrite_dns_records?).to be false
    end
  end
end
