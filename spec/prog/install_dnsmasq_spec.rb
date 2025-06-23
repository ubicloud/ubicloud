# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallDnsmasq do
  subject(:idm) {
    described_class.new(Strand.new(prog: "InstallDnsmasq"))
  }

  describe "#start" do
    it "starts sub-programs to install dependencies and download dnsmasq concurrently" do
      expect(idm).to receive(:bud).with(described_class, {}, :install_build_dependencies)
      expect(idm).to receive(:bud).with(described_class, {}, :git_clone_dnsmasq)

      expect { idm.start }.to hop("wait_downloads")
    end
  end

  describe "#wait_downloads" do
    before { expect(idm).to receive(:reap) }

    it "donates if any sub-progs are still running" do
      expect(idm).to receive(:leaf?).and_return false
      expect { idm.wait_downloads }.to nap(1)
    end

    it "hops to compile_and_install when the downloads are done" do
      expect(idm).to receive(:leaf?).and_return true
      expect { idm.wait_downloads }.to hop("compile_and_install")
    end
  end

  describe "#compile_and_install" do
    it "runs a compile command and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with "(cd dnsmasq && make -sj$(nproc) && sudo make install)"
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.compile_and_install }.to exit({"msg" => "compiled and installed dnsmasq"})
    end
  end

  describe "#install_build_dependencies" do
    it "installs dependencies and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with "sudo apt-get -y install make gcc"
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.install_build_dependencies }.to exit({"msg" => "installed build dependencies"})
    end
  end

  describe "#git_clone_dnsmasq" do
    it "fetches a version and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with <<CMD.rstrip
git init dnsmasq && (cd dnsmasq &&   git fetch https://github.com/ubicloud/dnsmasq.git b6769234bca9b0eabfe4768832b88d2cdb187092 --depth=1 &&  git checkout b6769234bca9b0eabfe4768832b88d2cdb187092 &&  git fsck --full)
CMD
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.git_clone_dnsmasq }.to exit({"msg" => "downloaded and verified dnsmasq successfully"})
    end
  end
end
