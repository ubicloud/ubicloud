# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallDnsmasq do
  subject(:idm) {
    described_class.new(st)
  }

  let(:st) { Strand.new(prog: "InstallDnsmasq") }

  describe "#start" do
    it "starts sub-programs to install dependencies and download dnsmasq concurrently" do
      expect(idm).to receive(:bud).with(described_class, {}, :install_build_dependencies)
      expect(idm).to receive(:bud).with(described_class, {}, :git_clone_dnsmasq)

      expect { idm.start }.to hop("wait_downloads")
    end
  end

  describe "#wait_downloads" do
    it "donates if any sub-progs are still running" do
      st.update(label: "wait_downloads", stack: [{}])
      Strand.create(parent_id: st.id, prog: "InstallDnsmasq", label: "install_build_dependencies", stack: [{}], lease: Time.now + 10)
      expect { idm.wait_downloads }.to nap(120)
    end

    it "hops to compile_and_install when the downloads are done" do
      st.update(label: "wait_downloads", stack: [{}])
      expect { idm.wait_downloads }.to hop("compile_and_install")
    end
  end

  describe "#compile_and_install" do
    it "runs a compile command and pops" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with "(cd dnsmasq && make -sj$(nproc) && sudo make install)"
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.compile_and_install }.to exit({"msg" => "compiled and installed dnsmasq"})
    end
  end

  describe "#install_build_dependencies" do
    it "installs dependencies and pops" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with "sudo apt-get -y install make gcc"
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.install_build_dependencies }.to exit({"msg" => "installed build dependencies"})
    end
  end

  describe "#git_clone_dnsmasq" do
    it "fetches a version and pops" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with <<CMD.rstrip
git init dnsmasq && (cd dnsmasq &&   git fetch https://github.com/ubicloud/dnsmasq.git b6769234bca9b0eabfe4768832b88d2cdb187092 --depth=1 &&  git checkout b6769234bca9b0eabfe4768832b88d2cdb187092 &&  git fsck --full)
CMD
      expect(idm).to receive(:sshable).and_return(sshable)

      expect { idm.git_clone_dnsmasq }.to exit({"msg" => "downloaded and verified dnsmasq successfully"})
    end
  end
end
