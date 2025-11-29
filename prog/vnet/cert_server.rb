# frozen_string_literal: true

class Prog::Vnet::CertServer < Prog::Base
  subject_is :load_balancer

  def vm
    @vm ||= Vm[frame.fetch("vm_id")]
  end

  label def before_run
    when_destroy_set? do
      pop "early exit due to destroy semaphore"
    end

    pop "vm is destroyed" unless vm
  end

  label def reshare_certificate
    put_cert_to_vm

    pop "certificate is reshared"
  end

  label def setup_cert_server
    vm.vm_host.sshable.cmd("sudo host/bin/setup-cert-server setup #{vm.inhost_name}")
    hop_put_certificate
  end

  label def put_certificate
    nap 5 unless load_balancer.active_cert&.cert
    put_cert_to_vm
    pop "certificate server is setup"
  end

  label def remove_cert_server
    vm.vm_host.sshable.cmd("sudo host/bin/setup-cert-server stop_and_remove #{vm.inhost_name}")
    pop "certificate resources and server are removed"
  end

  def put_cert_to_vm
    cert = load_balancer.active_cert
    fail "BUG: certificate is nil" unless cert&.cert

    cert_payload = cert.cert
    cert_key_payload = OpenSSL::PKey::EC.new(cert.csr_key).to_pem

    vm.vm_host.sshable.cmd("sudo host/bin/setup-cert-server put-certificate #{vm.inhost_name}", stdin: JSON.generate({cert_payload: cert_payload.to_s, cert_key_payload: cert_key_payload.to_s}))
  end
end
