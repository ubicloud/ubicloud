# frozen_string_literal: true

RSpec.describe Prog::Vnet::CertServer do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create(prog: "Vnet::CertServer", stack: [{"subject_id" => lb.id, "vm_id" => vm.id}], label: "update_load_balancer")
  }

  let(:cert) {
    lb.certs.first
  }

  let(:lb) {
    prj = Project.create(name: "test-prj")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
    lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080).subject
    dz = DnsZone.create(name: "test-dns-zone", project_id: prj.id)
    cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
    lb.add_cert(cert)
    lb
  }

  let(:vm) {
    vm_host = instance_double(VmHost, sshable: Sshable.new)
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
    it "puts the certificate and pops" do
      expect(nx).to receive(:put_cert_to_vm)
      expect { nx.reshare_certificate }.to exit({"msg" => "certificate is reshared"})
    end
  end

  describe "#put_certificate" do
    it "puts the certificate to vm and hops to start_certificate_server" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/setup-cert-server put-certificate test-vm", stdin: JSON.generate({cert_payload: "cert", cert_key_payload: OpenSSL::PKey::EC.new(cert.csr_key).to_pem}))
      expect { nx.put_certificate }.to exit({"msg" => "certificate server is setup"})
    end

    it "naps if load_balancer.active_cert is nil" do
      expect(nx.load_balancer).to receive(:active_cert).and_return(nil)
      expect { nx.put_certificate }.to nap(5)
    end
  end

  describe "#setup_cert_server" do
    it "starts the certificate server and pops" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/setup-cert-server setup test-vm")
      expect { nx.setup_cert_server }.to hop("put_certificate")
    end
  end

  describe "#remove_cert_server" do
    it "removes the certificate files, server and hops to remove_load_balancer" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/setup-cert-server stop_and_remove test-vm")

      expect { nx.remove_cert_server }.to exit({"msg" => "certificate resources and server are removed"})
    end
  end

  describe ".put_cert_to_vm" do
    it "fails if certificate is nil" do
      lb.certs.map { it.update(cert: nil) }
      expect { nx.put_cert_to_vm }.to raise_error(RuntimeError, "BUG: certificate is nil")
    end

    it "fails if certificate payload is nil" do
      lb.certs.map { it.update(cert: nil) }
      expect(nx.load_balancer).to receive(:active_cert).and_return(lb.certs.first)

      expect { nx.put_cert_to_vm }.to raise_error(RuntimeError, "BUG: certificate is nil")
    end
  end
end
