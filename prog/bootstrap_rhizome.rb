# frozen_string_literal: true

require_relative "../lib/util"

class Prog::BootstrapRhizome < Prog::Base
  subject_is :sshable

  required_input :target_folder
  optional_input :user, "root"

  label def start
    sshable.update(raw_private_key_1: SshKey.generate.keypair) if sshable.raw_private_key_1.nil?
    hop_setup
  end

  label def setup
    pop "rhizome user bootstrapped and source installed" if retval&.dig("msg") == "installed rhizome"

    key_data = sshable.keys.map(&:private_key)
    Util.rootish_ssh(sshable.host, user, key_data, <<SH)
set -ueo pipefail
sudo apt update && sudo apt-get -y install ruby-bundler
sudo userdel -rf rhizome || true
sudo adduser --disabled-password --gecos '' rhizome
echo 'rhizome ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/98-rhizome
sudo install -d -o rhizome -g rhizome -m 0700 /home/rhizome/.ssh
sudo install -o rhizome -g rhizome -m 0600 /dev/null /home/rhizome/.ssh/authorized_keys
echo #{sshable.keys.map(&:public_key).join("\n").shellescape} | sudo tee /home/rhizome/.ssh/authorized_keys > /dev/null
SH

    push Prog::InstallRhizome, {"target_folder" => target_folder}
  end
end
