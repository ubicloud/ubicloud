# frozen_string_literal: true

class Prog::InstallDnsmasq < Prog::Base
  subject_is :sshable

  label def start
    # Handle some short, non-dependent steps concurrently, keeping
    # overall code compact by self-budding and starting at a different
    # label.
    bud self.class, frame, :install_build_dependencies
    bud self.class, frame, :git_clone_dnsmasq

    hop_wait_downloads
  end

  label def wait_downloads
    reap(:compile_and_install)
  end

  label def compile_and_install
    sshable.cmd("(cd dnsmasq && make -sj$(nproc) && sudo make install)")
    pop "compiled and installed dnsmasq"
  end

  label def install_build_dependencies
    sshable.cmd("sudo apt-get -y install make gcc")
    pop "installed build dependencies"
  end

  label def git_clone_dnsmasq
    sshable.cmd("git init dnsmasq && " \
                "(cd dnsmasq && " \
                "  git fetch https://github.com/ubicloud/dnsmasq.git :commit --depth=1 &&" \
                "  git checkout :commit &&" \
                "  git fsck --full)", commit: "b6769234bca9b0eabfe4768832b88d2cdb187092")
    pop "downloaded and verified dnsmasq successfully"
  end
end
