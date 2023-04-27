# frozen_string_literal: true

class Prog::InstallDnsmasq < Prog::Base
  subject_is :sshable

  def start
    # Handle some short, non-dependent steps concurrently, keeping
    # overall code compact by self-budding and starting at a different
    # label.
    bud self.class, frame, :install_build_dependencies
    bud self.class, frame, :git_clone_dnsmasq

    hop :wait_downloads
  end

  def wait_downloads
    reap
    hop :compile_and_install if leaf?
    donate
  end

  def compile_and_install
    sshable.cmd("(cd dnsmasq && make -sj$(nproc) && sudo make install)")
    pop "compiled and installed dnsmasq"
  end

  def install_build_dependencies
    sshable.cmd("sudo apt-get -y install make gcc")
    pop "installed build dependencies"
  end

  def git_clone_dnsmasq
    sshable.cmd("git clone https://github.com/fdr/dnsmasq.git --depth=1 && " \
                "(cd dnsmasq && git checkout aaba66efbd3b4e7283993ca3718df47706a8549b && git fsck --full)")
    pop "downloaded and verified dnsmasq successfully"
  end
end
