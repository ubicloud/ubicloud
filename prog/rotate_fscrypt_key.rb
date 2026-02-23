# frozen_string_literal: true

require "json"

class Prog::RotateFscryptKey < Prog::Base
  subject_is :vm

  label def start
    unless vm.vm_metal&.fscrypt_key
      pop "vm does not use fscrypt"
    end

    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    kek_secrets = {
      "algorithm" => "aes-256-gcm",
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "auth_data" => "Ubicloud-fscrypt"
    }
    vm.vm_metal.update(fscrypt_key_2: JSON.generate(kek_secrets))

    hop_install
  end

  label def install
    vm_fscrypt("reencrypt", {
      old_key: JSON.parse(vm.vm_metal.fscrypt_key),
      new_key: JSON.parse(vm.vm_metal.fscrypt_key_2)
    })

    hop_test_keys
  end

  label def test_keys
    vm_fscrypt("test-keys", {
      old_key: JSON.parse(vm.vm_metal.fscrypt_key),
      new_key: JSON.parse(vm.vm_metal.fscrypt_key_2)
    })

    hop_promote_db
  end

  label def promote_db
    vm.vm_metal.update(fscrypt_key: vm.vm_metal.fscrypt_key_2, fscrypt_key_2: nil)

    hop_retire_old
  end

  label def retire_old
    vm_fscrypt("retire-old", {})

    pop "fscrypt key rotated"
  end

  def vm_name = @vm_name ||= vm.inhost_name
  def host = @host ||= vm.vm_host

  private

  def vm_fscrypt(action, json)
    host.sshable.cmd("sudo host/bin/vm-fscrypt :action :vm_name", action:, vm_name:, stdin: JSON.generate(json))
  end
end
