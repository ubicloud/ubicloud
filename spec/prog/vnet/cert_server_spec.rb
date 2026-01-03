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

  let(:vmh) { create_vm_host }
  let(:vm) { create_vm(vm_host_id: vmh.id) }

  def sshable
    @sshable ||= nx.vm.vm_host.sshable
  end

  describe ".before_run" do
    it "pops if vm is nil" do
      refresh_frame(nx, new_frame: {"subject_id" => lb.id, "vm_id" => SecureRandom.uuid})
      expect { nx.before_run }.to exit({"msg" => "vm is destroyed"})
    end

    it "pops if destroy semaphore is set" do
      nx.incr_destroy
      expect { nx.before_run }.to exit({"msg" => "exiting early due to destroy semaphore"})
    end

    it "if vm exists, does nothing" do
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#reshare_certificate" do
    it "puts the certificate and pops" do
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-cert-server put-certificate #{vm.inhost_name}", stdin: JSON.generate({cert_payload: "cert", cert_key_payload: OpenSSL::PKey::EC.new(cert.csr_key).to_pem}))
      expect { nx.reshare_certificate }.to exit({"msg" => "certificate is reshared"})
    end
  end

  describe "#put_certificate" do
    it "puts the certificate to vm and hops to start_certificate_server" do
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-cert-server put-certificate #{vm.inhost_name}", stdin: JSON.generate({cert_payload: "cert", cert_key_payload: OpenSSL::PKey::EC.new(cert.csr_key).to_pem}))
      expect { nx.put_certificate }.to exit({"msg" => "certificate server is setup"})
    end

    it "naps if load_balancer.active_cert is nil" do
      lb.certs.each(&:destroy)
      expect { nx.put_certificate }.to nap(5)
    end
  end

  describe "#setup_cert_server" do
    it "starts the certificate server and pops" do
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-cert-server setup #{vm.inhost_name}")
      expect { nx.setup_cert_server }.to hop("put_certificate")
    end
  end

  describe "#remove_cert_server" do
    it "removes the certificate files, server and hops to remove_load_balancer" do
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-cert-server stop_and_remove #{vm.inhost_name}")

      expect { nx.remove_cert_server }.to exit({"msg" => "certificate resources and server are removed"})
    end
  end

  describe ".put_cert_to_vm" do
    it "fails if certificate is nil" do
      lb.certs.each(&:destroy)
      expect { nx.put_cert_to_vm }.to raise_error(RuntimeError, "BUG: certificate is nil")
    end

    it "fails if certificate payload is nil" do
      cert.update(cert: nil)
      expect { nx.put_cert_to_vm }.to raise_error(RuntimeError, "BUG: certificate is nil")
    end
  end
end
