# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LoadBalancer do
  subject(:lb) {
    prj = Project.create_with_id(name: "test-prj").tap { _1.associate_with_project(_1) }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps")
    Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 80).subject
  }

  let(:vm1) {
    prj = lb.private_subnet.projects.first
    Prog::Vm::Nexus.assemble("pub-key", prj.id, name: "test-vm1", private_subnet_id: lb.private_subnet.id).subject
  }

  describe "util funcs" do
    before do
      allow(Config).to receive(:load_balancer_service_hostname).and_return("lb.ubicloud.com")
    end

    it "returns hyper_tag_name" do
      prj = lb.private_subnet.projects.first
      expect(lb.hyper_tag_name(prj)).to eq("project/#{prj.ubid}/location/eu-central-h1/load-balancer/test-lb")
    end

    it "returns hostname" do
      expect(lb.hostname).to eq("test-lb.#{lb.private_subnet.ubid[-5...]}.lb.ubicloud.com")
    end
  end

  describe "add_vm" do
    it "increments update_load_balancer and rewrite_dns_records" do
      expect(lb).to receive(:incr_rewrite_dns_records)
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.projects.first.id)
      cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
      lb.add_cert(cert)
      lb.add_vm(vm1)
      expect(lb.load_balancers_vms.count).to eq(1)
    end
  end

  describe "evacuate_vm" do
    let(:ce) {
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.projects.first.id)
      Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    }

    before do
      lb.add_cert(ce)
      lb.add_vm(vm1)
    end

    it "increments update_load_balancer and rewrite_dns_records" do
      expect(lb).to receive(:incr_update_load_balancer)
      expect(lb).to receive(:incr_rewrite_dns_records)
      health_probe = instance_double(Strand, stack: [{"subject_id" => lb.id, "vm_id" => vm1.id}])
      expect(lb.strand).to receive(:children_dataset).and_return(instance_double(Sequel::Dataset, where: instance_double(Sequel::Dataset, all: [health_probe])))
      expect(health_probe).to receive(:destroy)
      lb.evacuate_vm(vm1)
      expect(lb.load_balancers_vms.first[:state]).to eq("evacuating")
    end
  end

  describe "remove_vm" do
    let(:ce) {
      dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.projects.first.id)
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

  describe "need_certificates?" do
    let(:dns_zone) {
      DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.private_subnet.projects.first.id)
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
      expect(lb.need_certificates?).to be(false)
    end
  end

  describe "active_cert" do
    let(:dns_zone) {
      DnsZone.create_with_id(name: "test-dns-zone", project_id: lb.private_subnet.projects.first.id)
    }

    it "returns the cert that is not expired" do
      cert1 = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      cert2 = Prog::Vnet::CertNexus.assemble(lb.hostname, dns_zone.id).subject
      lb.add_cert(cert1)
      lb.add_cert(cert2)

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
