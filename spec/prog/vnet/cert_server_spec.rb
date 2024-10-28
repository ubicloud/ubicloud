# frozen_string_literal: true

RSpec.describe Prog::Vnet::CertServer do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create_with_id(prog: "Vnet::CertServer", stack: [{"subject_id" => lb.id, "vm_id" => vm.id}], label: "update_load_balancer")
  }

  let(:cert) {
    lb.certs.first
  }

  let(:lb) {
    prj = Project.create_with_id(name: "test-prj").tap { _1.associate_with_project(_1) }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
    lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080).subject
    dz = DnsZone.create_with_id(name: "test-dns-zone", project_id: prj.id)
    cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
    lb.add_cert(cert)
    lb
  }

  let(:vm) {
    vm_host = instance_double(VmHost, sshable: instance_double(Sshable))
    instance_double(Vm, inhost_name: "test-vm", vm_host: vm_host, id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
  }

  before do
    allow(lb).to receive(:active_cert).and_return(lb.certs.first)
    allow(Vm).to receive(:[]).and_return(vm)
  end

  describe ".before_run" do
    it "pops if vm is nil" do
      expect(nx).to receive(:vm).and_return(nil)
      expect { nx.before_run }.to exit({"msg" => "vm is destroyed"})
    end

    it "if vm exists, does nothing" do
      expect(nx).to receive(:vm).and_return(vm)
      nx.before_run
    end
  end

  describe "#reshare_certificate" do
    it "reates a certificate folder, puts the certificate and pops" do
      expect(nx).to receive(:put_cert_to_vm)
      expect { nx.reshare_certificate }.to exit({"msg" => "certificate is reshared"})
    end
  end

  describe "#put_certificate" do
    it "creates a certificate folder, puts the certificate and hops to start_certificate_server" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo -u #{vm.inhost_name} mkdir -p /vm/#{vm.inhost_name}/cert")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo -u #{vm.inhost_name} tee /vm/#{vm.inhost_name}/cert/cert.pem", stdin: "cert")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo -u #{vm.inhost_name} tee /vm/#{vm.inhost_name}/cert/key.pem", stdin: OpenSSL::PKey::EC.new(cert.csr_key).to_pem)
      expect { nx.put_certificate }.to hop("start_certificate_server")
    end

    it "naps if load_balancer.active_cert is nil" do
      expect(nx.load_balancer).to receive(:active_cert).and_return(nil)
      expect { nx.put_certificate }.to nap(5)
    end
  end

  describe "#start_certificate_server" do
    it "starts the certificate server and pops" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo host/bin/setup-cert-server setup test-vm")
      expect { nx.start_certificate_server }.to exit({"msg" => "certificate server is started"})
    end
  end

  describe "#remove_cert_server" do
    it "removes the certificate files, server and hops to remove_load_balancer" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo host/bin/setup-cert-server stop_and_remove test-vm")

      expect { nx.remove_cert_server }.to exit({"msg" => "certificate resources and server are removed"})
    end
  end
end
