# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Hetzner::InstallOs do
  subject(:prog) { described_class.new(st) }

  let(:vm_host) { Prog::Vm::HostNexus.assemble("192.168.0.1").subject }
  let(:st) { Strand.new(prog: "Hetzner::InstallOs", stack: [{"subject_id" => vm_host.id}]) }
  let(:sshable) { prog.sshable }

  describe "#start" do
    it "fails if the hostname is not rescue" do
      expect(prog).to receive(:setup_root_cmd).with("hostname").and_return("existing-host\n")
      expect { prog.start }.to raise_error RuntimeError, "Host is not in rescue mode: hostname is \"existing-host\" instead of \"rescue\""
    end

    it "fails if installimage is not available" do
      expect(prog).to receive(:setup_root_cmd).with("hostname").and_return("rescue\n")
      expect(prog).to receive(:setup_root_cmd).with("test -x :path && echo y || true", path: described_class::INSTALLIMAGE).and_return("\n")
      expect { prog.start }.to raise_error RuntimeError, "Host is not in rescue mode: installimage is not available"
    end

    it "hops to install if the host is in rescue mode" do
      expect(prog).to receive(:setup_root_cmd).with("hostname").and_return("rescue\n")
      expect(prog).to receive(:setup_root_cmd).with("test -x :path && echo y || true", path: described_class::INSTALLIMAGE).and_return("y\n")
      expect { prog.start }.to hop("install")
    end
  end

  describe "#install" do
    let(:install_script) { <<~SCRIPT }
      set -ue
      if [ "$(hostname)" != "rescue" ]; then
        echo "refusing to install the OS: host is not in rescue mode"
        exit 1
      fi
      image_name="$1"
      rm -f /root/ubicloud-install.exit
      trap 'echo $? > /root/ubicloud-install.exit' EXIT
      /root/.oldroot/nfs/install/installimage -a -r no -d nvme0n1 -p /boot/efi:esp:256M,swap:swap:32G,/boot:ext3:1024M,/:ext4:all -i "images/${image_name}"
    SCRIPT

    it "starts installimage with the x64 image" do
      expect(prog).to receive(:setup_root_cmd).with("uname -m").and_return("x86_64\n")
      expect(prog).to receive(:setup_root_cmd).with("echo :script > /root/ubicloud-install.sh", script: install_script)
      expect(prog).to receive(:setup_root_cmd).with("nohup bash /root/ubicloud-install.sh :image_name > /root/ubicloud-install.log 2>&1 < /dev/null & echo started", image_name: "Ubuntu-2404-noble-amd64-base.tar.zst")
      expect { prog.install }.to hop("wait_install")
    end

    it "starts installimage with the arm64 image" do
      expect(prog).to receive(:setup_root_cmd).with("uname -m").and_return("aarch64\n")
      expect(prog).to receive(:setup_root_cmd).with("echo :script > /root/ubicloud-install.sh", script: install_script)
      expect(prog).to receive(:setup_root_cmd).with("nohup bash /root/ubicloud-install.sh :image_name > /root/ubicloud-install.log 2>&1 < /dev/null & echo started", image_name: "Ubuntu-2404-noble-arm64-base.tar.zst")
      expect { prog.install }.to hop("wait_install")
    end

    it "fails for an unexpected architecture" do
      expect(prog).to receive(:setup_root_cmd).with("uname -m").and_return("riscv64\n")
      expect { prog.install }.to raise_error RuntimeError, "Unexpected machine architecture \"riscv64\" reported by the rescue system"
    end
  end

  describe "#wait_install" do
    it "naps if installimage is still running" do
      expect(prog).to receive(:setup_root_cmd).with("cat /root/ubicloud-install.exit 2> /dev/null || true").and_return("\n")
      expect { prog.wait_install }.to nap(30)
    end

    it "fails if installimage failed" do
      expect(prog).to receive(:setup_root_cmd).with("cat /root/ubicloud-install.exit 2> /dev/null || true").and_return("1\n")
      expect(prog).to receive(:setup_root_cmd).with("tail -n 40 /root/ubicloud-install.log 2> /dev/null || true").and_return("something went wrong")
      expect { prog.wait_install }.to raise_error RuntimeError, "installimage failed with exit status 1: something went wrong"
    end

    it "reboots and hops to wait_reboot if installimage succeeded" do
      expect(prog).to receive(:setup_root_cmd).with("cat /root/ubicloud-install.exit 2> /dev/null || true").and_return("0\n")
      expect(prog).to receive(:setup_root_cmd).with("reboot")
      expect { prog.wait_install }.to hop("wait_reboot")
    end
  end

  describe "#wait_reboot" do
    it "naps if the host is still in rescue mode" do
      expect(prog).to receive(:setup_root_cmd).with("hostname").and_return("rescue\n")
      expect { prog.wait_reboot }.to nap(30)
    end

    it "pops once the host boots into the installed OS" do
      expect(prog).to receive(:setup_root_cmd).with("hostname").and_return("Ubuntu-2404-noble-amd64-base\n")
      expect { prog.wait_reboot }.to exit({"msg" => "operating system installed"})
    end
  end

  describe "#setup_root_cmd" do
    it "fails if the hetzner ssh private key is not configured" do
      expect(Config).to receive(:hetzner_ssh_private_key).and_return(nil)
      expect { prog.setup_root_cmd("hostname") }.to raise_error RuntimeError, "BUG: hetzner_ssh_private_key is not set"
    end

    it "runs the command on the host as root with the hetzner key" do
      root_key = SshKey.generate
      expect(Config).to receive(:hetzner_ssh_private_key).at_least(:once).and_return(root_key.private_key)
      expect(Util).to receive(:rootish_ssh).with("192.168.0.1", "root", [instance_of(String)], "echo :value", value: 1).and_return("1\n")
      expect(prog.setup_root_cmd("echo :value", value: 1)).to eq("1\n")
    end

    it "naps if the host is not reachable" do
      root_key = SshKey.generate
      expect(Config).to receive(:hetzner_ssh_private_key).at_least(:once).and_return(root_key.private_key)
      expect(Util).to receive(:rootish_ssh).and_raise(Errno::ECONNREFUSED)
      expect { prog.setup_root_cmd("hostname") }.to nap(30)
    end
  end
end
