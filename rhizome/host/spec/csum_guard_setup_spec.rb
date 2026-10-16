# frozen_string_literal: true

require_relative "../lib/csum_guard_setup"

RSpec.describe CsumGuardSetup do
  subject(:cgs) { described_class.new }

  let(:object) { "/opt/csum-guard/csum_guard-#{described_class::VERSION}.bpf.o" }
  let(:lock) { instance_double(File) }
  let(:calls) { [] }

  def expect_lock
    expect(File).to receive(:open).with(described_class::LOCK_PATH, File::RDWR | File::CREAT).and_yield(lock)
    expect(lock).to receive(:flock).with(File::LOCK_EX) { calls << :lock }
  end

  def expect_attach(netns, tap, obj)
    expect(cgs).to receive(:_run_command).with("tc", "-n", netns, "qdisc", "replace", "dev", tap, "clsact")
    expect(cgs).to receive(:_run_command).with("tc", "-n", netns, "filter", "replace", "dev", tap, "ingress", "pref", "49152", "handle", "1",
      "bpf", "direct-action", "object-file", obj, "section", "tc") { calls << [:attach, tap] }
  end

  def expect_netns_list(json)
    expect(cgs).to receive(:_run_command).with("ip", "-j", "netns", "list").and_return(json)
  end

  def expect_taps(netns, json)
    expect(cgs).to receive(:_run_command).with("ip", "-n", netns, "-j", "link", "show", "type", "tun").and_return(json)
  end

  describe ".maybe_attach_vm" do
    it "delegates to an instance" do
      instance = instance_double(described_class)
      expect(described_class).to receive(:new).and_return(instance)
      expect(instance).to receive(:maybe_attach_vm).with("vm1", ["tap1"])

      described_class.maybe_attach_vm("vm1", ["tap1"])
    end
  end

  describe "#install" do
    it "checks the kernel, then downloads and attaches every tap under the lock" do
      expect(cgs).to receive(:check_kernel) { calls << :kernel }
      expect_lock
      expect(cgs).to receive(:download_object) { calls << :download }
      expect(cgs).to receive(:each_vm_tap).and_yield("vm1", "tap1").and_yield("vm2", "tap2")
      expect_attach("vm1", "tap1", object)
      expect_attach("vm2", "tap2", object)

      cgs.install
      expect(calls).to eq([:kernel, :lock, :download, [:attach, "tap1"], [:attach, "tap2"]])
    end
  end

  describe "#uninstall" do
    it "removes the object and detaches every tap under the lock" do
      expect_lock
      expect(FileUtils).to receive(:rm_f).with(object) { calls << :remove }
      expect(cgs).to receive(:each_vm_tap).and_yield("vm1", "tap1")
      expect(cgs).to receive(:_run_command).with("tc", "-n", "vm1", "filter", "del", "dev", "tap1", "ingress", "pref", "49152", expect: [0, 2]) { calls << :detach }

      cgs.uninstall
      expect(calls).to eq([:lock, :remove, :detach])
    end
  end

  describe "#maybe_attach_vm" do
    it "attaches the object, without the lock" do
      expect(File).not_to receive(:open)
      expect(File).to receive(:exist?).with(object).and_return(true)
      expect_attach("vm1", "tap1", object)
      expect_attach("vm1", "tap2", object)

      cgs.maybe_attach_vm("vm1", ["tap1", "tap2"])
    end

    it "does nothing while the guard is not installed" do
      expect(File).to receive(:exist?).with(object).and_return(false)
      expect(cgs).not_to receive(:_run_command)

      cgs.maybe_attach_vm("vm1", ["tap1"])
    end

    it "gives up when an uninstall removes the object under it" do
      expect(File).to receive(:exist?).with(object).and_return(true, false)
      expect(cgs).to receive(:attach).with("vm1", "tap1", object).and_raise(CommandFail.new("", "", "No such file"))

      expect { cgs.maybe_attach_vm("vm1", ["tap1", "tap2"]) }.not_to raise_error
    end

    it "fails when the object is still there" do
      expect(File).to receive(:exist?).with(object).and_return(true, true)
      expect(cgs).to receive(:attach).and_raise(CommandFail.new("", "", "verifier"))

      expect { cgs.maybe_attach_vm("vm1", ["tap1"]) }.to raise_error(CommandFail)
    end
  end

  describe "#check_kernel" do
    it "accepts the minimum kernel" do
      expect(cgs).to receive(:_run_command).with("uname -r").and_return("6.3.0-1-generic\n")

      expect { cgs.check_kernel }.not_to raise_error
    end

    it "refuses an older kernel" do
      expect(cgs).to receive(:_run_command).with("uname -r").and_return("5.15.0-1052-generic\n")

      expect { cgs.check_kernel }.to raise_error(/Kernel 5.15.0-1052-generic is older than 6.3/)
    end

    it "fails on a release it cannot parse" do
      expect(cgs).to receive(:_run_command).with("uname -r").and_return("linux\n")

      expect { cgs.check_kernel }.to raise_error(/Cannot parse kernel release "linux"/)
    end
  end

  describe "#download_object" do
    it "publishes the object once it matches its digest and loads" do
      expect(File).to receive(:exist?).with(object).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/opt/csum-guard")
      expect(cgs).to receive(:safe_write_to_file).with(object) do |_, &blk|
        expect(cgs).to receive(:curl_file).with(cgs.object_url, "#{object}.tmp")
          .and_return(described_class::OBJECT_SHA256)
        expect(cgs).to receive(:probe).with("#{object}.tmp")
        blk.call(instance_double(File, path: "#{object}.tmp"))
      end

      cgs.download_object
    end

    it "fails when the digest does not match" do
      expect(File).to receive(:exist?).with(object).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/opt/csum-guard")
      expect(cgs).to receive(:safe_write_to_file).with(object) do |_, &blk|
        expect(cgs).to receive(:curl_file).and_return("deadbeef")
        expect(cgs).not_to receive(:probe)
        blk.call(instance_double(File, path: "#{object}.tmp"))
      end

      expect { cgs.download_object }.to raise_error(/Invalid SHA-256 digest/)
    end

    it "does not download when the object is already present" do
      expect(File).to receive(:exist?).with(object).and_return(true)
      expect(cgs).not_to receive(:safe_write_to_file)

      cgs.download_object
    end
  end

  describe "#probe" do
    it "loads the object onto a tap in a throwaway namespace and removes it" do
      expect(cgs).to receive(:_run_command).with("ip", "netns", "del", "csum-guard-probe", expect: [0, 1]).twice
      expect(cgs).to receive(:_run_command).with("ip", "netns", "add", "csum-guard-probe")
      expect(cgs).to receive(:_run_command).with("ip", "-n", "csum-guard-probe", "tuntap", "add", "dev", "probe", "mode", "tap")
      expect_attach("csum-guard-probe", "probe", "#{object}.tmp")

      cgs.probe("#{object}.tmp")
    end

    it "removes the namespace when the object does not load" do
      expect(cgs).to receive(:_run_command).with("ip", "netns", "del", "csum-guard-probe", expect: [0, 1]).twice
      expect(cgs).to receive(:_run_command).with("ip", "netns", "add", "csum-guard-probe")
      expect(cgs).to receive(:_run_command).with("ip", "-n", "csum-guard-probe", "tuntap", "add", "dev", "probe", "mode", "tap")
      expect(cgs).to receive(:attach).and_raise(CommandFail.new("tc failed", "", "verifier"))

      expect { cgs.probe("#{object}.tmp") }.to raise_error(CommandFail)
    end
  end

  describe "#each_vm_tap" do
    it "yields the tun devices in every named namespace" do
      expect_netns_list('[{"name":"vm1","id":0},{"name":"vm2"}]')
      expect_taps("vm1", '[{"ifindex":3,"ifname":"tap1"},{"ifindex":4,"ifname":"tap1b"}]')
      expect_taps("vm2", "[]")

      expect { |b| cgs.each_vm_tap(&b) }.to yield_successive_args(["vm1", "tap1"], ["vm1", "tap1b"])
    end

    it "yields nothing without namespaces" do
      expect_netns_list("[]")

      expect { |b| cgs.each_vm_tap(&b) }.not_to yield_control
    end

    it "skips a namespace deleted after the listing" do
      expect_netns_list('[{"name":"vm1"},{"name":"vm2"}]')
      expect(cgs).to receive(:_run_command).with("ip", "-n", "vm1", "-j", "link", "show", "type", "tun")
        .and_raise(CommandFail.new("", "", "Cannot open network namespace"))
      expect(File).to receive(:exist?).with("/var/run/netns/vm1").and_return(false)
      expect_taps("vm2", '[{"ifname":"tap2"}]')

      expect { |b| cgs.each_vm_tap(&b) }.to yield_successive_args(["vm2", "tap2"])
    end

    it "fails when listing a namespace that still exists fails" do
      expect_netns_list('[{"name":"vm1"}]')
      expect(cgs).to receive(:_run_command).with("ip", "-n", "vm1", "-j", "link", "show", "type", "tun")
        .and_raise(CommandFail.new("", "", "error"))
      expect(File).to receive(:exist?).with("/var/run/netns/vm1").and_return(true)

      expect { cgs.each_vm_tap {} }.to raise_error(CommandFail)
    end

    it "skips a tap deleted during its turn" do
      expect_netns_list('[{"name":"vm1"}]')
      expect_taps("vm1", '[{"ifname":"tap1"},{"ifname":"tap2"}]')
      expect(cgs).to receive(:tap_gone?).with("vm1", "tap1").and_return(true)
      seen = []

      cgs.each_vm_tap do |_, tap|
        seen << tap
        raise CommandFail.new("", "", "Cannot find device") if tap == "tap1"
      end
      expect(seen).to eq(["tap1", "tap2"])
    end

    it "fails when a tap that still exists fails" do
      expect_netns_list('[{"name":"vm1"}]')
      expect_taps("vm1", '[{"ifname":"tap1"}]')
      expect(cgs).to receive(:tap_gone?).with("vm1", "tap1").and_return(false)

      expect { cgs.each_vm_tap { raise CommandFail.new("", "", "verifier") } }.to raise_error(CommandFail)
    end
  end

  describe "#tap_gone?" do
    it "is true when ip finds no tap" do
      expect(cgs).to receive(:_run_command).with("ip", "-n", "vm1", "link", "show", "dev", "tap1", expect: [0, 1, 255]).and_return("")

      expect(cgs.tap_gone?("vm1", "tap1")).to be(true)
    end

    it "is false when ip shows the tap" do
      expect(cgs).to receive(:_run_command).with("ip", "-n", "vm1", "link", "show", "dev", "tap1", expect: [0, 1, 255])
        .and_return("5: tap1: <BROADCAST,MULTICAST> mtu 1500\n")

      expect(cgs.tap_gone?("vm1", "tap1")).to be(false)
    end
  end

  describe "OBJECT_SHA256" do
    it "is a sha256 digest" do
      expect(described_class::OBJECT_SHA256).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe "#object_url" do
    it "names the release asset" do
      expect(cgs.object_url).to eq(
        "https://github.com/ubicloud/csum-guard/releases/download/v#{described_class::VERSION}/csum_guard.bpf.o",
      )
    end
  end
end
