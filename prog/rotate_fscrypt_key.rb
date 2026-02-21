# frozen_string_literal: true

require "json"

class Prog::RotateFscryptKey < Prog::Base
  subject_is :vm

  label def start
    unless vm.fscrypt_key
      pop "vm does not use fscrypt"
    end

    new_key = Base64.encode64(OpenSSL::Random.random_bytes(32))
    vm.update(fscrypt_key_2: new_key)

    hop_add_protector
  end

  label def add_protector
    old_key_binary = Base64.decode64(vm.fscrypt_key)
    new_key_binary = Base64.decode64(vm.fscrypt_key_2)

    host.sshable.cmd(
      "sudo host/bin/setup-vm rotate-fscrypt-add :vm_name",
      vm_name:, stdin: JSON.generate({
        old_key: Base64.strict_encode64(old_key_binary),
        new_key: Base64.strict_encode64(new_key_binary)
      })
    )

    hop_promote_db
  end

  label def promote_db
    vm.update(fscrypt_key: vm.fscrypt_key_2, fscrypt_key_2: nil)
    hop_remove_old
  end

  label def remove_old
    keep_key_binary = Base64.decode64(vm.fscrypt_key)

    host.sshable.cmd(
      "sudo host/bin/setup-vm rotate-fscrypt-remove :vm_name",
      vm_name:, stdin: JSON.generate({
        keep_key: Base64.strict_encode64(keep_key_binary)
      })
    )

    pop "fscrypt key rotated"
  end

  def vm_name = @vm_name ||= vm.inhost_name
  def host = @host ||= vm.vm_host
end
