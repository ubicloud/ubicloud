# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallNetworkingTools do
  subject(:idm) {
    described_class.new(Strand.new(prog: "InstallNetworkingTools"))
  }

  describe "#start" do
    it "starts sub-programs to install dependencies and download dnsmasq concurrently" do
      expect(idm).to receive(:bud).with(described_class, {}, :install_build_dependencies)
      expect(idm).to receive(:bud).with(described_class, {}, :git_clone_dnsmasq)
      expect(idm).to receive(:bud).with(described_class, {}, :git_clone_radvd)

      expect { idm.start }.to hop("wait_downloads")
    end
  end

  describe "#wait_downloads" do
    before { expect(idm).to receive(:reap) }

    it "donates if any sub-progs are still running" do
      expect(idm).to receive(:donate).and_call_original
      expect(idm).to receive(:leaf?).and_return false
      expect { idm.wait_downloads }.to nap(0)
    end

    it "hops to compile_and_install when the downloads are done" do
      expect(idm).to receive(:leaf?).and_return true
      expect(idm).to receive(:bud).with(described_class, {}, :compile_and_install_dnsmasq)
      expect(idm).to receive(:bud).with(described_class, {}, :compile_and_install_radvd)
      expect { idm.wait_downloads }.to hop("wait_install")
    end
  end

  describe "#compile_and_install_dnsmasq" do
    it "runs a compile command and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with "(cd dnsmasq && make -sj$(nproc) && sudo make install)"
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.compile_and_install_dnsmasq }.to exit({"msg" => "compiled and installed dnsmasq"})
    end
  end

  describe "#compile_and_install_radvd" do
    it "runs a compile command and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with "(cd radvd && ./autogen.sh && ./configure && make -sj$(nproc) && sudo make install)"
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.compile_and_install_radvd }.to exit({"msg" => "compiled and installed radvd"})
    end
  end

  describe "#wait_install" do
    before { expect(idm).to receive(:reap) }

    it "donates if any sub-progs are still running" do
      expect(idm).to receive(:donate).and_call_original
      expect(idm).to receive(:leaf?).and_return false
      expect { idm.wait_install }.to nap(0)
    end

    it "pops when the installs are done" do
      expect(idm).to receive(:leaf?).and_return true
      expect { idm.wait_install }.to exit({"msg" => "installed networking tools"})
    end
  end

  describe "#install_build_dependencies" do
    it "installs dependencies and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with "sudo apt-get -y install make gcc pkg-config automake bison flex"
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.install_build_dependencies }.to exit({"msg" => "installed build dependencies"})
    end
  end

  describe "#git_clone_dnsmasq" do
    it "fetches a version and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with <<CMD.rstrip
git init dnsmasq && (cd dnsmasq &&   git fetch https://github.com/ubicloud/dnsmasq.git aaba66efbd3b4e7283993ca3718df47706a8549b --depth=1 &&  git checkout aaba66efbd3b4e7283993ca3718df47706a8549b &&  git fsck --full)
CMD
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.git_clone_dnsmasq }.to exit({"msg" => "downloaded and verified dnsmasq successfully"})
    end
  end

  describe "#git_clone_radvd" do
    it "fetches a version and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with <<CMD.rstrip
git init radvd && (cd radvd &&   git fetch https://github.com/ubicloud/radvd.git f85392a68c7cd0fe5525b4218be07b893402b69b --depth=1 &&  git checkout f85392a68c7cd0fe5525b4218be07b893402b69b &&  git fsck --full)
CMD
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.git_clone_radvd }.to exit({"msg" => "downloaded and verified radvd successfully"})
    end
  end
end
