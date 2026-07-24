# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Hetzner::InstallOs do
  subject(:prog) { described_class.new(st) }

  let(:vm_host) { Prog::Vm::HostNexus.assemble("192.168.0.1").subject }
  let(:st) { Strand.new(prog: "Hetzner::InstallOs", stack: [{"subject_id" => vm_host.id}]) }

  let(:session) { Net::SSH::Connection::Session.allocate }

  before do
    allow(Config).to receive(:hetzner_ssh_private_key).and_return(SshKey.generate.private_key)
    allow(Net::SSH).to receive(:start) { |*, **, &blk| blk.call(session) }
  end

  def ssh_result(stdout, exitstatus = 0)
    Net::SSH::Connection::Session::StringWithExitstatus.new(stdout, exitstatus)
  end

  describe "#start" do
    it "fails if the hostname is not rescue" do
      expect(session).to receive(:_exec!).with("hostname").and_return(ssh_result("existing-host\n"))
      expect { prog.start }.to raise_error RuntimeError, "Host is not in rescue mode: hostname is \"existing-host\" instead of \"rescue\""
    end

    it "fails if installimage is not available" do
      expect(session).to receive(:_exec!).with("hostname").and_return(ssh_result("rescue\n"))
      expect(session).to receive(:_exec!).with("test -x #{described_class::INSTALLIMAGE.shellescape} && echo y || true").and_return(ssh_result("\n"))
      expect { prog.start }.to raise_error RuntimeError, "Host is not in rescue mode: installimage is not available"
    end

    it "hops to install if the host is in rescue mode" do
      expect(session).to receive(:_exec!).with("hostname").and_return(ssh_result("rescue\n"))
      expect(session).to receive(:_exec!).with("test -x #{described_class::INSTALLIMAGE.shellescape} && echo y || true").and_return(ssh_result("y\n"))
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
      mdadm --stop /dev/md/* 2>/dev/null || true
      wipefs -fa /dev/nvme*n1
      /root/.oldroot/nfs/install/installimage -a -r no -d nvme0n1 -p /boot/efi:esp:256M,swap:swap:32G,/boot:ext3:1024M,/:ext4:all -i "images/${image_name}"
    SCRIPT

    it "starts installimage with the x64 image" do
      expect(session).to receive(:_exec!).with("uname -m").and_return(ssh_result("x86_64\n"))
      expect(session).to receive(:_exec!).with("echo #{install_script.shellescape} > /root/ubicloud-install.sh").and_return(ssh_result(""))
      expect(session).to receive(:_exec!).with("nohup bash /root/ubicloud-install.sh Ubuntu-2404-noble-amd64-base.tar.zst > /root/ubicloud-install.log 2>&1 < /dev/null & echo started").and_return(ssh_result("started\n"))
      expect { prog.install }.to hop("wait_install")
    end

    it "starts installimage with the arm64 image" do
      expect(session).to receive(:_exec!).with("uname -m").and_return(ssh_result("aarch64\n"))
      expect(session).to receive(:_exec!).with("echo #{install_script.shellescape} > /root/ubicloud-install.sh").and_return(ssh_result(""))
      expect(session).to receive(:_exec!).with("nohup bash /root/ubicloud-install.sh Ubuntu-2404-noble-arm64-base.tar.zst > /root/ubicloud-install.log 2>&1 < /dev/null & echo started").and_return(ssh_result("started\n"))
      expect { prog.install }.to hop("wait_install")
    end

    it "fails for an unexpected architecture" do
      expect(session).to receive(:_exec!).with("uname -m").and_return(ssh_result("riscv64\n"))
      expect { prog.install }.to raise_error RuntimeError, "Unexpected machine architecture \"riscv64\" reported by the rescue system"
    end
  end

  describe "#wait_install" do
    it "naps if installimage is still running" do
      expect(session).to receive(:_exec!).with("cat /root/ubicloud-install.exit 2> /dev/null || true").and_return(ssh_result("\n"))
      expect { prog.wait_install }.to nap(30)
    end

    it "fails if installimage failed" do
      expect(session).to receive(:_exec!).with("cat /root/ubicloud-install.exit 2> /dev/null || true").and_return(ssh_result("1\n"))
      expect(session).to receive(:_exec!).with("tail -n 40 /root/ubicloud-install.log 2> /dev/null || true").and_return(ssh_result("something went wrong"))
      expect { prog.wait_install }.to raise_error RuntimeError, "installimage failed with exit status 1: something went wrong"
    end

    it "reboots and hops to wait_reboot if installimage succeeded" do
      expect(session).to receive(:_exec!).with("cat /root/ubicloud-install.exit 2> /dev/null || true").and_return(ssh_result("0\n"))
      expect(session).to receive(:_exec!).with("reboot").and_return(ssh_result(""))
      expect { prog.wait_install }.to hop("wait_reboot")
    end
  end

  describe "#wait_reboot" do
    it "naps if the host is still in rescue mode" do
      expect(session).to receive(:_exec!).with("hostname").and_return(ssh_result("rescue\n"))
      expect { prog.wait_reboot }.to nap(30)
    end

    it "fails if a RAID array is present after the install" do
      expect(session).to receive(:_exec!).with("hostname").and_return(ssh_result("Ubuntu-2404-noble-amd64-base\n"))
      expect(session).to receive(:_exec!).with("cat /proc/mdstat").and_return(ssh_result("Personalities : [raid1]\nmd0 : active raid1 nvme0n1p3[0]\nunused devices: <none>\n"))
      expect { prog.wait_reboot }.to raise_error(RuntimeError, /Unexpected RAID array found after OS install/)
    end

    it "pops once the host boots into the installed OS with no RAID" do
      expect(session).to receive(:_exec!).with("hostname").and_return(ssh_result("Ubuntu-2404-noble-amd64-base\n"))
      expect(session).to receive(:_exec!).with("cat /proc/mdstat").and_return(ssh_result("Personalities : [raid1]\nunused devices: <none>\n"))
      expect { prog.wait_reboot }.to exit({"msg" => "operating system installed"})
    end
  end

  describe "#setup_root_cmd" do
    it "fails if the hetzner ssh private key is not configured" do
      expect(Config).to receive(:hetzner_ssh_private_key).and_return(nil)
      expect { prog.setup_root_cmd("hostname") }.to raise_error RuntimeError, "BUG: hetzner_ssh_private_key is not set"
    end

    it "runs the command on the host as root and returns the output" do
      expect(Net::SSH).to receive(:start).with("192.168.0.1", "root", anything) { |*, **, &blk| blk.call(session) }
      expect(session).to receive(:_exec!).with("echo 1").and_return(ssh_result("1\n"))
      expect(prog.setup_root_cmd("echo :value", value: 1)).to eq("1\n")
    end

    it "naps if the host is not reachable" do
      expect(Net::SSH).to receive(:start).and_raise(Errno::ECONNREFUSED)
      expect { prog.setup_root_cmd("hostname") }.to nap(30)
    end
  end
end
