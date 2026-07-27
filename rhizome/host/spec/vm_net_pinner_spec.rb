# frozen_string_literal: true

require_relative "../lib/vm_net_pinner"

RSpec.describe VmNetPinner do
  subject(:pinner) { described_class.new("vm6mh19c", "2-5", 4) }

  describe "#initialize" do
    it "rejects an invalid vm name" do
      expect { described_class.new("foo", "2-5", 4) }.to raise_error(/invalid vm name/)
      expect { described_class.new("vm6/mh9c", "2-5", 4) }.to raise_error(/invalid vm name/)
    end

    it "rejects an invalid cpu list" do
      expect { described_class.new("vm6mh19c", "0;reboot", 4) }.to raise_error(/invalid cpu list/)
      expect { described_class.new("vm6mh19c", "", 4) }.to raise_error(/invalid cpu list/)
    end

    it "rejects a non-numeric thread count" do
      expect { described_class.new("vm6mh19c", "2-5", "4; reboot") }.to raise_error(ArgumentError)
    end
  end

  describe "#vp" do
    it "memoizes the VmPath" do
      first = pinner.vp
      expect(first).to be_a(VmPath)
      expect(pinner.vp).to be(first)
    end
  end

  describe "#dropin_dir" do
    it "is the unit's drop-in directory" do
      expect(pinner.dropin_dir).to eq("/etc/systemd/system/vm6mh19c.service.d")
    end
  end

  describe "#main_pid" do
    it "returns the systemd MainPID" do
      expect(pinner).to receive(:_run_command).with("systemctl", "show", "-p", "MainPID", "--value", "vm6mh19c.service").and_return("12345\n")
      expect(pinner.main_pid).to eq(12345)
    end

    it "fails when the VM has no running process" do
      expect(pinner).to receive(:_run_command).with("systemctl", "show", "-p", "MainPID", "--value", "vm6mh19c.service").and_return("0\n")
      expect { pinner.main_pid }.to raise_error(/no running process/)
    end
  end

  describe "#net_thread_ids" do
    it "returns sorted tids of net worker threads, skipping others and vanished ones" do
      expect(Dir).to receive(:glob).with("/proc/999/task/*").and_return(
        ["/proc/999/task/30", "/proc/999/task/10", "/proc/999/task/20", "/proc/999/task/40"],
      )
      expect(File).to receive(:read).with("/proc/999/task/30/comm").and_return("_net6_qp1\n")
      expect(File).to receive(:read).with("/proc/999/task/10/comm").and_return("_net6_qp0\n")
      expect(File).to receive(:read).with("/proc/999/task/20/comm").and_return("vcpu0\n")
      expect(File).to receive(:read).with("/proc/999/task/40/comm").and_raise(Errno::ENOENT)
      expect(pinner.net_thread_ids(999)).to eq([10, 30])
    end
  end

  describe "#wait_net_thread_ids" do
    it "returns once all the threads are there" do
      expect(pinner).to receive(:net_thread_ids).with(999).and_return([10, 11, 12, 13])
      expect(pinner).not_to receive(:sleep)
      expect(pinner.wait_net_thread_ids(999)).to eq([10, 11, 12, 13])
    end

    it "waits while only some of the threads are up" do
      expect(pinner).to receive(:net_thread_ids).with(999).and_return([10, 11], [10, 11, 12, 13])
      expect(pinner).to receive(:sleep).with(1).once
      expect(pinner.wait_net_thread_ids(999)).to eq([10, 11, 12, 13])
    end

    it "fails after exhausting the bounded retries" do
      expect(pinner).to receive(:net_thread_ids).with(999).and_return([]).exactly(described_class::THREAD_WAIT_TRIES).times
      expect(pinner).to receive(:sleep).with(1).exactly(described_class::THREAD_WAIT_TRIES).times
      expect { pinner.wait_net_thread_ids(999) }.to raise_error(/expected 4 virtio-net worker threads/)
    end
  end

  describe "#expand" do
    it "expands ranges and singletons" do
      expect(pinner.expand("2-4,7")).to eq([2, 3, 4, 7])
    end
  end

  describe "#dropin_command" do
    it "carries the cpu list and the thread count" do
      expect(pinner.dropin_command).to match(%r{/rhizome/host/bin/pin-vm-net-threads pin vm6mh19c 2-5 4\z})
    end
  end

  describe "#pin" do
    it "pins each net thread round-robin across the target cpus" do
      expect(pinner).to receive(:main_pid).and_return(999)
      expect(pinner).to receive(:wait_net_thread_ids).with(999).and_return([10, 11, 12, 13])
      expect(pinner).to receive(:_run_command).with("taskset", "-pc", "2", "10")
      expect(pinner).to receive(:_run_command).with("taskset", "-pc", "3", "11")
      expect(pinner).to receive(:_run_command).with("taskset", "-pc", "4", "12")
      expect(pinner).to receive(:_run_command).with("taskset", "-pc", "5", "13")
      pinner.pin
    end
  end

  describe "#install" do
    it "writes the drop-in, reloads systemd, and pins" do
      expect(pinner).to receive(:dropin_dir).and_return("/etc/systemd/system/vm6mh19c.service.d").twice
      expect(FileUtils).to receive(:mkdir_p).with("/etc/systemd/system/vm6mh19c.service.d")
      expect(File).to receive(:write).with(
        "/etc/systemd/system/vm6mh19c.service.d/10-net-pin.conf",
        a_string_matching(%r{\A\[Service\]\nExecStartPost=-\+/\S+/pin-vm-net-threads pin vm6mh19c 2-5 4\n\z}),
      )
      expect(pinner).to receive(:_run_command).with("systemctl daemon-reload")
      expect(pinner).to receive(:pin)
      pinner.install
    end
  end
end
