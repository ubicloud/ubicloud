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
    reap
    hop_compile_and_install if leaf?
    donate
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
    q_commit = "aaba66efbd3b4e7283993ca3718df47706a8549b".shellescape
    sshable.cmd("git init dnsmasq && " \
                "(cd dnsmasq && " \
                "  git fetch https://github.com/fdr/dnsmasq.git #{q_commit} --depth=1 &&" \
                "  git checkout #{q_commit} &&" \
                "  git fsck --full)")
    pop "downloaded and verified dnsmasq successfully"
  end
end
