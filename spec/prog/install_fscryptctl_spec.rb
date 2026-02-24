# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallFscryptctl do
  subject(:ifc) {
    described_class.new(st)
  }

  let(:sshable) { Sshable.create }
  let(:st) { Strand.create_with_id(sshable, prog: "InstallFscryptctl", label: "start") }

  describe "#start" do
    it "starts sub-programs to install dependencies and download fscryptctl concurrently" do
      expect(ifc).to receive(:bud).with(described_class, {}, :install_build_dependencies)
      expect(ifc).to receive(:bud).with(described_class, {}, :git_clone_fscryptctl)

      expect { ifc.start }.to hop("wait_downloads")
    end
  end

  describe "#wait_downloads" do
    it "donates if any sub-progs are still running" do
      st.update(label: "wait_downloads", stack: [{}])
      Strand.create(parent_id: st.id, prog: "InstallFscryptctl", label: "install_build_dependencies", stack: [{}], lease: Time.now + 10)
      expect { ifc.wait_downloads }.to nap(120)
    end

    it "hops to compile_and_install when the downloads are done" do
      st.update(label: "wait_downloads", stack: [{}])
      expect { ifc.wait_downloads }.to hop("compile_and_install")
    end
  end

  describe "#compile_and_install" do
    it "runs a compile command and pops" do
      expect(ifc.sshable).to receive(:_cmd).with "(cd fscryptctl && make fscryptctl && sudo install -m755 fscryptctl /usr/local/bin/fscryptctl)"
      expect { ifc.compile_and_install }.to exit({"msg" => "compiled and installed fscryptctl"})
    end
  end

  describe "#install_build_dependencies" do
    it "installs dependencies and pops" do
      expect(ifc.sshable).to receive(:_cmd).with "sudo apt-get -y install make gcc"
      expect { ifc.install_build_dependencies }.to exit({"msg" => "installed build dependencies"})
    end
  end

  describe "#git_clone_fscryptctl" do
    it "fetches a version and pops" do
      expect(ifc.sshable).to receive(:_cmd).with <<CMD.rstrip
git init fscryptctl && (cd fscryptctl &&   git fetch https://github.com/google/fscryptctl.git f1ec919877f6b5360c03fdb44b6ed8a47aa459e8 --depth=1 &&  git checkout f1ec919877f6b5360c03fdb44b6ed8a47aa459e8 &&  git fsck --full)
CMD
      expect { ifc.git_clone_fscryptctl }.to exit({"msg" => "downloaded and verified fscryptctl successfully"})
    end
  end
end
