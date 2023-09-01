# frozen_string_literal: true

class Prog::InstallNetworkingTools < Prog::Base
  subject_is :sshable

  label def start
    # Handle some short, non-dependent steps concurrently, keeping
    # overall code compact by self-budding and starting at a different
    # label.
    bud self.class, frame, :install_build_dependencies
    bud self.class, frame, :git_clone_dnsmasq
    bud self.class, frame, :git_clone_radvd

    hop_wait_downloads
  end

  label def wait_downloads
    reap
    if leaf?
      bud self.class, frame, :compile_and_install_dnsmasq
      bud self.class, frame, :compile_and_install_radvd
      hop_wait_install
    end
    donate
  end

  label def compile_and_install_dnsmasq
    sshable.cmd("(cd dnsmasq && make -sj$(nproc) && sudo make install)")
    pop "compiled and installed dnsmasq"
  end

  label def compile_and_install_radvd
    sshable.cmd("(cd radvd && ./autogen.sh && " \
      "./configure && make -sj$(nproc) && sudo make install)")
    pop "compiled and installed radvd"
  end

  label def wait_install
    reap
    pop "installed networking tools" if leaf?
    donate
  end

  label def install_build_dependencies
    sshable.cmd("sudo apt-get -y install make gcc pkg-config automake bison flex")
    pop "installed build dependencies"
  end

  label def git_clone_dnsmasq
    q_commit = "aaba66efbd3b4e7283993ca3718df47706a8549b".shellescape
    sshable.cmd("git init dnsmasq && " \
                "(cd dnsmasq && " \
                "  git fetch https://github.com/ubicloud/dnsmasq.git #{q_commit} --depth=1 &&" \
                "  git checkout #{q_commit} &&" \
                "  git fsck --full)")
    pop "downloaded and verified dnsmasq successfully"
  end

  label def git_clone_radvd
    q_commit = "f85392a68c7cd0fe5525b4218be07b893402b69b".shellescape
    sshable.cmd("git init radvd && " \
                "(cd radvd && " \
                "  git fetch https://github.com/ubicloud/radvd.git #{q_commit} --depth=1 &&" \
                "  git checkout #{q_commit} &&" \
                "  git fsck --full)")
    pop "downloaded and verified radvd successfully"
  end
end
