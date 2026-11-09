# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnOs do
  subject(:lo) { described_class.new(Strand.create_with_id(sshable, prog: "LearnOs", label: "start")) }

  let(:sshable) { Sshable.create }

  describe "#start" do
    it "exits, saving Ubuntu OS version" do
      expect(lo.sshable).to receive(:_cmd).with("cat /etc/os-release").and_return(<<~OS_RELEASE)
        PRETTY_NAME="Ubuntu 24.04.3 LTS"
        NAME="Ubuntu"
        VERSION_ID="24.04"
        ID=ubuntu
        ID_LIKE=debian
      OS_RELEASE
      expect { lo.start }.to exit(os_version: "ubuntu-24.04")
    end

    it "exits, saving Debian OS version" do
      expect(lo.sshable).to receive(:_cmd).with("cat /etc/os-release").and_return(<<~OS_RELEASE)
        PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
        NAME="Debian GNU/Linux"
        VERSION_ID="13"
        VERSION_CODENAME=trixie
        ID=debian
      OS_RELEASE
      expect { lo.start }.to exit(os_version: "debian-13")
    end

    it "fails if the OS id cannot be determined" do
      expect(lo.sshable).to receive(:_cmd).with("cat /etc/os-release").and_return("ID_LIKE=debian\nVERSION_ID=\"13\"\n")
      expect { lo.start }.to raise_error RuntimeError, "unable to determine OS id from /etc/os-release"
    end

    it "fails if the OS version cannot be determined" do
      expect(lo.sshable).to receive(:_cmd).with("cat /etc/os-release").and_return("ID=debian\n")
      expect { lo.start }.to raise_error RuntimeError, "unable to determine OS version from /etc/os-release"
    end
  end
end
