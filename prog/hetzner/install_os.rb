# frozen_string_literal: true

class Prog::Hetzner::InstallOs < Prog::Base
  subject_is :sshable

  # The rescue system exposes installimage as a shell alias, which is only
  # available in interactive shells. We run it through its real path so it
  # works over a non-interactive SSH command.
  INSTALLIMAGE = "/root/.oldroot/nfs/install/installimage"

  label def start
    hostname = setup_root_cmd("hostname").strip
    fail "Host is not in rescue mode: hostname is #{hostname.inspect} instead of \"rescue\"" unless hostname == "rescue"
    fail "Host is not in rescue mode: installimage is not available" if setup_root_cmd("test -x :path && echo y || true", path: INSTALLIMAGE).strip.empty?

    hop_install
  end

  label def install
    image_name = case (machine = setup_root_cmd("uname -m").strip)
    when "x86_64" then "Ubuntu-2404-noble-amd64-base.tar.zst"
    when "aarch64" then "Ubuntu-2404-noble-arm64-base.tar.zst"
    else fail "Unexpected machine architecture #{machine.inspect} reported by the rescue system"
    end

    # Installs the OS to the first disk; the hostname check is a last line of
    # defense against reimaging a live host.
    # https://docs.hetzner.com/robot/dedicated-server/operating-systems/installimage/
    setup_root_cmd("echo :script > /root/ubicloud-install.sh", script: <<~SCRIPT)
      set -ue
      if [ "$(hostname)" != "rescue" ]; then
        echo "refusing to install the OS: host is not in rescue mode"
        exit 1
      fi
      image_name="$1"
      rm -f /root/ubicloud-install.exit
      trap 'echo $? > /root/ubicloud-install.exit' EXIT
      #{INSTALLIMAGE} -a -r no -d nvme0n1 -p /boot/efi:esp:256M,swap:swap:32G,/boot:ext3:1024M,/:ext4:all -i "images/${image_name}"
    SCRIPT
    setup_root_cmd("nohup bash /root/ubicloud-install.sh :image_name > /root/ubicloud-install.log 2>&1 < /dev/null & echo started", image_name:)

    hop_wait_install
  end

  label def wait_install
    exit_status = setup_root_cmd("cat /root/ubicloud-install.exit 2> /dev/null || true").strip
    nap 30 if exit_status.empty?

    unless exit_status == "0"
      install_log = setup_root_cmd("tail -n 40 /root/ubicloud-install.log 2> /dev/null || true")
      fail "installimage failed with exit status #{exit_status}: #{install_log}"
    end

    setup_root_cmd("reboot")
    hop_wait_reboot
  end

  label def wait_reboot
    nap 30 if setup_root_cmd("hostname").strip == "rescue"

    pop "operating system installed"
  end

  def setup_root_cmd(cmd, **kwargs)
    fail "BUG: hetzner_ssh_private_key is not set" unless Config.hetzner_ssh_private_key

    root_key = Net::SSH::Authentication::ED25519::PrivKey.read(Config.hetzner_ssh_private_key, Config.hetzner_ssh_private_key_passphrase).sign_key
    Util.rootish_ssh(sshable.host, "root", [SshKey.from_binary(root_key.keypair).private_key], cmd, **kwargs)
  rescue *Sshable::SSH_CONNECTION_ERRORS
    nap 30
  end
end
