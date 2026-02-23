# frozen_string_literal: true

class Prog::InstallFscryptctl < Prog::Base
  subject_is :sshable

  label def start
    # Handle some short, non-dependent steps concurrently, keeping
    # overall code compact by self-budding and starting at a different
    # label.
    bud self.class, frame, :install_build_dependencies
    bud self.class, frame, :git_clone_fscryptctl

    hop_wait_downloads
  end

  label def wait_downloads
    reap(:compile_and_install)
  end

  label def compile_and_install
    sshable.cmd("(cd fscryptctl && make fscryptctl && sudo install -m755 fscryptctl /usr/local/bin/fscryptctl)")
    pop "compiled and installed fscryptctl"
  end

  label def install_build_dependencies
    sshable.cmd("sudo apt-get -y install make gcc")
    pop "installed build dependencies"
  end

  label def git_clone_fscryptctl
    sshable.cmd("git init fscryptctl && " \
                "(cd fscryptctl && " \
                "  git fetch https://github.com/google/fscryptctl.git :commit --depth=1 &&" \
                "  git checkout :commit &&" \
                "  git fsck --full)", commit: "f1ec919877f6b5360c03fdb44b6ed8a47aa459e8")
    pop "downloaded and verified fscryptctl successfully"
  end
end
