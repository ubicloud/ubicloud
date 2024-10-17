# frozen_string_literal: true

class Prog::Vnet::CertServer < Prog::Base
  subject_is :load_balancer

  def vm
    @vm ||= Vm[frame.fetch("vm_id")]
  end

  def cert_folder
    "/vm/#{vm.inhost_name}/cert"
  end

  def cert_path
    "#{cert_folder}/cert.pem"
  end

  def key_path
    "#{cert_folder}/key.pem"
  end

  label def before_run
    pop "vm is destroyed" unless vm
  end

  label def reshare_certificate
    put_cert_to_vm

    pop "certificate is reshared"
  end

  label def put_certificate
    nap 5 unless load_balancer.active_cert&.cert

    put_cert_to_vm
    hop_start_certificate_server
  end

  label def start_certificate_server
    vm.vm_host.sshable.cmd("sudo host/bin/setup-cert-server setup #{vm.inhost_name}")
    pop "certificate server is started"
  end

  label def remove_cert_server
    vm.vm_host.sshable.cmd("sudo host/bin/setup-cert-server stop_and_remove #{vm.inhost_name}")
    pop "certificate resources and server are removed"
  end

  def put_cert_to_vm
    cert = load_balancer.active_cert

    cert_payload = cert.cert
    cert_key_payload = OpenSSL::PKey::EC.new(cert.csr_key).to_pem
    vm.vm_host.sshable.cmd("sudo -u #{vm.inhost_name} mkdir -p #{cert_folder}")
    vm.vm_host.sshable.cmd("sudo -u #{vm.inhost_name} tee #{cert_path}", stdin: cert_payload)
    vm.vm_host.sshable.cmd("sudo -u #{vm.inhost_name} tee #{key_path}", stdin: cert_key_payload)
  end
end
