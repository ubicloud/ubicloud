# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LoadBalancer do
  subject(:lb) {
    prj = Project.create_with_id(name: "test-prj")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps")
    Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080, health_check_protocol: "https").subject
  }

  let(:vm1) {
    prj = lb.private_subnet.project
    Prog::Vm::Nexus.assemble("pub key", prj.id, name: "test-vm1", private_subnet_id: lb.private_subnet.id).subject
  }

  it "disallows VM ubid format as name" do
    ps = described_class.new(name: described_class.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to eq ["cannot be exactly 26 numbers/lowercase characters starting with 1b to avoid overlap with id format"]
  end

  it "allows inference endpoint ubid format as name" do
    ps = described_class.new(name: InferenceEndpoint.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to be_nil
  end

  describe "util funcs" do
    before do
      allow(Config).to receive(:load_balancer_service_hostname).and_return("lb.ubicloud.com")
    end

    it "returns hostname" do
      expect(lb.hostname).to eq("test-lb.#{lb.private_subnet.ubid[-5...]}.lb.ubicloud.com")
    end
  end

  describe "add_port" do
    before do
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.project_id)
      cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
      lb.add_vm(vm1)
      lb.reload
      lb.add_cert(cert)
    end

    it "adds the new port and increments update_load_balancer" do
      expect(lb).to receive(:incr_update_load_balancer)
      expect(lb.vm_ports.count).to eq(1)
      lb.add_port(443, 8443)
      lb.reload
      expect(lb.vm_ports.count).to eq(2)
      expect(lb.ports.count).to eq(2)
    end
  end

  describe "remove_port" do
    before do
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.project_id)
      cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
      lb.add_vm(vm1)
      lb.reload
      lb.add_cert(cert)
    end

    it "removes the new port and increments update_load_balancer" do
      expect(lb).to receive(:incr_update_load_balancer).twice
      lb.add_port(443, 8443)
      lb.reload
      expect(lb.vm_ports.count).to eq(2)
      expect(lb.ports.count).to eq(2)

      lb.remove_port(lb.ports[1])
      lb.reload
      expect(lb.ports.count).to eq(1)
      expect(lb.vm_ports.count).to eq(1)
    end
  end

  describe "add_vm" do
    it "increments update_load_balancer and rewrite_dns_records" do
      expect(lb).to receive(:incr_rewrite_dns_records)
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.project_id)
      cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
      lb.add_cert(cert)
      lb.add_vm(vm1)
      expect(lb.load_balancers_vms.count).to eq(1)
    end
  end

  describe "evacuate_vm" do
    let(:ce) {
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.project_id)
      Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    }

    before do
      lb.add_cert(ce)
      lb.add_vm(vm1)
    end

    it "increments update_load_balancer and rewrite_dns_records" do
      expect(lb).to receive(:incr_update_load_balancer)
      expect(lb).to receive(:incr_rewrite_dns_records)
      lb.evacuate_vm(vm1)
      expect(lb.vm_ports.first[:state]).to eq("evacuating")
    end
  end

  describe "remove_vm" do
    let(:ce) {
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.project_id)
      Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    }

    before do
      lb.add_cert(ce)
      lb.add_vm(vm1)
    end

    it "deletes the vm" do
      lb.remove_vm(vm1)
      expect(lb.load_balancers_vms.count).to eq(0)
    end
  end

  describe "remove_vm_port" do
    let(:ce) {
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.project_id)
      Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    }

    before do
      lb.add_cert(ce)
      lb.add_vm(vm1)
    end

    it "deletes the load_balancer_vm_port" do
      new_port = LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 443, dst_port: 8443)
      LoadBalancerVmPort.create(load_balancer_port_id: new_port.id, load_balancer_vm_id: lb.load_balancers_vms.first.id)
      lb.reload
      expect(lb.vm_ports.count).to eq(2)
      lb.remove_vm_port(lb.vm_ports.first)
      lb.reload
      expect(lb.vm_ports.count).to eq(1)
      expect(lb.load_balancers_vms.count).to eq(1)
    end

    it "deletes the load_balancer_vm_port. also deletes load_balancers_vms if the deleted vm_port was the last one" do
      lb.remove_vm_port(lb.vm_ports.first)
      lb.reload
      expect(lb.vm_ports.count).to eq(0)
      expect(lb.load_balancers_vms.count).to eq(0)
    end
  end

  describe "need_certificates?" do
    let(:dns_zone) {
      DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.private_subnet.project_id)
    }

    it "returns true if there are no certs" do
      expect(lb.need_certificates?).to be(true)
    end

    it "returns false if there are certs but either expired or close to expiry" do
      cert = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      lb.add_cert(cert)

      cert.update(created_at: Time.now - 1 * 365 * 24 * 60 * 60)
      expect(lb.need_certificates?).to be(true)
    end

    it "returns false if there are certs and they are not expired" do
      cert = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      lb.add_cert(cert)
      cert.update(cert: "cert")
      expect(lb.need_certificates?).to be(false)
    end

    it "returns true if there are certs and they are not expired but the cert field is empty" do
      cert = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      lb.add_cert(cert)
      expect(lb.need_certificates?).to be(true)
    end

    it "returns false if health_check_protocol is not https" do
      lb.update(health_check_protocol: "http")
      expect(lb.need_certificates?).to be(false)
      lb.update(health_check_protocol: "tcp")
      expect(lb.need_certificates?).to be(false)
    end
  end

  describe "active_cert" do
    let(:dns_zone) {
      DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.private_subnet.project_id)
    }

    it "returns the cert that is not expired" do
      cert1 = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      cert2 = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      lb.add_cert(cert1)
      lb.add_cert(cert2)

      cert1.update(cert: "cert")
      cert2.update(cert: "cert")
      cert1.update(created_at: Time.now - 1 * 365 * 24 * 60 * 60)
      expect(lb.active_cert.id).to eq(cert2.id)
    end

    it "returns nil if all certs are expired" do
      cert = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      lb.add_cert(cert)

      cert.update(created_at: Time.now - 1 * 365 * 24 * 60 * 60)
      expect(lb.active_cert).to be_nil
    end
  end
end
