# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe VmHostSlice do
  subject(:vm_host_slice) do
    described_class.create(
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
  end

  let(:vm_host) { create_vm_host(total_cores: 4, total_cpus: 8, used_cores: 1) }

  before do
    allow(vm_host_slice).to receive(:vm_host).and_return(vm_host)
    (0..15).each { |i|
      VmHostCpu.create(
        vm_host_id: vm_host.id,
        cpu_number: i,
        spdk: i < 2,
        vm_host_slice_id: (i == 2 || i == 3) ? vm_host_slice.id : nil
      )
    }
  end

  describe "enforce object is valid" do
    it "validates name and family" do
      slice = described_class.new
      slice.enabled = true
      slice.is_shared = false
      slice.cores = 1
      slice.total_cpu_percent = 200
      slice.used_cpu_percent = 0
      slice.total_memory_gib = 8
      slice.used_memory_gib = 0
      slice.vm_host_id = vm_host.id

      expect(slice.valid?).to be false
      expect(slice.errors).to eq(name: ["is not present"], family: ["is not present"])

      slice.name = ""
      slice.family = ""
      expect(slice.valid?).to be false
      expect(slice.errors).to eq(name: ["is not present"], family: ["is not present"])

      slice.family = "standard"

      slice.name = "user"
      expect(slice.valid?).to be false
      expect(slice.errors).to eq(name: ["cannot be 'user' or 'system'"])

      slice.name = "system"
      expect(slice.valid?).to be false
      expect(slice.errors).to eq(name: ["cannot be 'user' or 'system'"])

      slice.name = "system-standard"
      expect(slice.valid?).to be false
      expect(slice.errors).to eq(name: ["cannot contain a hyphen (-)"])

      slice.name = "standard"
      expect(slice.valid?).to be true
    end
  end

  describe "#allowed_cpus_cgroup" do
    it "returns the correct allowed_cpus_cgroup" do
      expect(vm_host_slice.allowed_cpus_cgroup).to eq("2-3")
    end

    it "returns the correct allowed_cpus_group if we have multiple disjoint cpus" do
      VmHostCpu.where(
        vm_host_id: vm_host.id,
        cpu_number: [2, 3, 6, 11, 12, 13]
      ).update(vm_host_slice_id: vm_host_slice.id)
      expect(vm_host_slice.allowed_cpus_cgroup).to eq("2-3,6,11-13")
    end
  end

  describe "#set_allowed_cpus" do
    it "sets the allowed cpus when cpu/core ratio is 2" do
      vm_host.update(total_cpus: 8, total_cores: 4)
      vm_host_slice.set_allowed_cpus([4, 5])
      expect(vm_host_slice.cores).to eq(1)
      expect(vm_host_slice.total_cpu_percent).to eq(200)
    end

    it "sets the allowed cpus when cpu/core ratio is 1" do
      vm_host.update(total_cpus: 8, total_cores: 8)
      vm_host_slice.set_allowed_cpus([4, 5, 6, 7])
      expect(vm_host_slice.cores).to eq(4)
      expect(vm_host_slice.total_cpu_percent).to eq(400)
    end

    it "raises an error if not enough cpus are available" do
      expect {
        vm_host_slice.set_allowed_cpus([2, 3, 4])
      }.to raise_error("Not enough CPUs available.")
    end
  end

  describe "#inhost_name" do
    it "returns the correct inhost_name" do
      expect(vm_host_slice.inhost_name).to eq("standard.slice")
    end
  end

  describe "availability monitoring" do
    it "initiates a new health monitor session" do
      allow(vm_host_slice).to receive_messages(vm_host: vm_host)
      expect(vm_host.sshable).to receive(:start_fresh_session)
      vm_host_slice.init_health_monitor_session
    end

    it "checks pulse" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host_slice).to receive_messages(vm_host: vm_host)

      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice").at_least(:once)
      expect(session[:ssh_session]).to receive(:_exec!).with("systemctl is-active standard.slice").and_return("active\nactive\n").once
      expect(session[:ssh_session]).to receive(:_exec!).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.effective").and_return("2-3\n").once
      expect(session[:ssh_session]).to receive(:_exec!).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.partition").and_return("root\n").once
      expect(vm_host_slice.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("up")

      expect(session[:ssh_session]).to receive(:_exec!).with("systemctl is-active standard.slice").and_return("active\ninactive\n").once
      expect(vm_host_slice).to receive(:reload).and_return(vm_host_slice)
      expect(vm_host_slice).to receive(:incr_checkup)
      expect(vm_host_slice.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")

      expect(session[:ssh_session]).to receive(:_exec!).and_raise Sshable::SshError
      expect(vm_host_slice).to receive(:reload).and_return(vm_host_slice)
      expect(vm_host_slice).to receive(:incr_checkup)
      expect(vm_host_slice.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
    end
  end
end
