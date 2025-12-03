# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/vm/vm_host_slice_nexus"
require_relative "../../../prog/vm/host_nexus"

RSpec.describe Prog::Vm::VmHostSliceNexus do
  subject(:nx) { described_class.new(Strand.create(id: "b231a172-8f56-8b10-bbed-8916ea4e5c28", prog: "Prog::Vm::VmHostSliceNexus", label: "create")) }

  let(:sshable) { vm_host.sshable }

  let(:vm_host) { create_vm_host(total_cores: 4, used_cores: 1) }

  let(:vm_host_slice) {
    VmHostSlice.create(
      vm_host_id: vm_host.id,
      name: "standard",
      family: "standard",
      is_shared: false,
      cores: 1,
      total_cpu_percent: 200,
      used_cpu_percent: 0,
      total_memory_gib: 4,
      used_memory_gib: 0
    )
  }

  before do
    allow(nx).to receive_messages(vm_host_slice: vm_host_slice)
    allow(vm_host_slice).to receive_messages(vm_host: vm_host)
    (0..15).each { |i|
      VmHostCpu.create(
        spdk: i < 2,
        vm_host_slice_id: (i == 2 || i == 3) ? vm_host_slice.id : nil
      ) {
        it.vm_host_id = vm_host.id
        it.cpu_number = i
      }
    }
  end

  describe ".assemble_with_host" do
    it "creates vm host slice" do
      # prepare the host for the test
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil
      host.update(total_cpus: 8, total_cores: 4)

      (0..15).each { |i|
        VmHostCpu.create(vm_host_id: host.id, cpu_number: i, spdk: i < 2)
      }

      # run the assemble test
      st_rg = described_class.assemble_with_host("standard", host, family: "standard", allowed_cpus: [2, 3], memory_gib: 4)
      rg = st_rg.subject
      expect(rg).not_to be_nil
      expect(rg.name).to eq("standard")
      expect(rg.allowed_cpus_cgroup).to eq("2-3")
      expect(rg.cores).to eq(1)
      expect(rg.total_cpu_percent).to eq(200)
      expect(rg.used_cpu_percent).to eq(0)
      expect(rg.total_memory_gib).to eq(4)
      expect(rg.used_memory_gib).to eq(0)
      expect(rg.enabled).to be(false)
      expect(rg.is_shared).to be(false)
      expect(rg.id).to eq(st_rg.id)
      expect(rg.ubid).to eq(st_rg.ubid)
      expect(rg.ubid[..1] == "vs").to be true
      expect(rg.vm_host).not_to be_nil
      expect(rg.vm_host.id).to eq(host.id)
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#prep" do
    it "starts prep on NotStarted" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_standard").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo host/bin/setup-slice prep standard.slice \"2-3\"' prep_standard")
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.prep }.to nap(1)
    end

    it "starts prep on Failed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_standard").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo host/bin/setup-slice prep standard.slice \"2-3\"' prep_standard")
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.prep }.to nap(1)
    end

    it "hops to wait" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_standard").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean prep_standard")

      expect { nx.prep }.to hop("wait")
    end

    it "do nothing on random result" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_standard").and_return("foobar")

      expect { nx.prep }.to nap(1)
    end
  end

  describe "#wait" do
    it "naps for 6 hours" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to start_after_host_reboot when signaled" do
      expect(nx).to receive(:when_start_after_host_reboot_set?).and_yield
      expect(nx).to receive(:register_deadline).with(:wait, 5 * 60)
      expect { nx.wait }.to hop("start_after_host_reboot")
    end

    it "hops to unavailable based on the slice's available status" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")

      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_raise Sshable::SshError.new("ssh failed", "", "", nil, nil)
      expect { nx.wait }.to hop("unavailable")

      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      expect(vm_host_slice).to receive(:destroy)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-slice delete standard.slice")
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.destroy }.to exit({"msg" => "vm_host_slice destroyed"})
    end
  end

  describe "#start_after_host_reboot" do
    it "starts slice on the host and hops to wait" do
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-slice recreate-unpersisted standard.slice")
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.start_after_host_reboot }.to hop("wait")
    end
  end

  describe "#unavailable" do
    it "hops to start_after_host_reboot when needed" do
      expect(nx).to receive(:when_start_after_host_reboot_set?).and_yield
      expect(nx).to receive(:incr_checkup)
      expect { nx.unavailable }.to hop("start_after_host_reboot")
    end

    it "registers an immediate deadline if slice is unavailable" do
      expect(nx).to receive(:register_deadline).with("wait", 0)
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "hops to wait if slice is available" do
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.unavailable }.to hop("wait")
    end
  end

  describe "#available?" do
    let(:session) { Net::SSH::Connection::Session.allocate }

    before do
      expect(sshable).to receive(:start_fresh_session).and_yield(session)
      expect(session).to receive(:_exec!).with("systemctl is-active standard.slice").and_return("active\nactive\n").once
      expect(session).to receive(:_exec!).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.effective").and_return("2-3\n").once
    end

    it "succeeds if the partition status is root" do
      expect(session).to receive(:_exec!).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.partition").and_return("root\n").once
      expect(nx.available?).to be true
    end

    it "succeeds if the partition status is member" do
      expect(session).to receive(:_exec!).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.partition").and_return("member\n").once
      expect(nx.available?).to be true
    end

    it "fails on the incorrect partition status" do
      expect(session).to receive(:_exec!).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.partition").and_return("isolated\n").once
      expect(nx.available?).to be false
    end
  end
end
