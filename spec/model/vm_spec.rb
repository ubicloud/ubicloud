# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vm do
  subject(:vm) { described_class.new(display_state: "creating") }

  describe "#display_state" do
    it "returns deleting if destroy semaphore increased" do
      expect(vm).to receive(:semaphores).and_return([instance_double(Semaphore, name: "destroy")])
      expect(vm.display_state).to eq("deleting")
    end

    it "return same if semaphores not increased" do
      expect(vm.display_state).to eq("creating")
    end
  end

  describe "#mem_gib" do
    it "handles standard-2" do
      vm.family = "standard"
      vm.cores = 1
      expect(vm.mem_gib).to eq 8
    end

    it "handles standard-16" do
      vm.family = "standard"
      vm.cores = 8
      expect(vm.mem_gib).to eq 64
    end
  end

  describe "#cloud_hypervisor_cpu_topology" do
    it "scales a single-socket hyperthreaded system" do
      vm.family = "standard"
      vm.cores = 2
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 6,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "scales a dual-socket hyperthreaded system" do
      vm.family = "standard"
      vm.cores = 2
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_dies: 2,
        total_sockets: 2
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "crashes if total_cpus is not multiply of total_cores" do
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 3,
        total_cores: 2
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if total_dies is not a multiple of total_sockets" do
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_dies: 3,
        total_sockets: 2
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if cores allocated per die is not uniform number" do
      vm.family = "standard"
      vm.cores = 2

      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 1,
        total_cores: 1,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG: need uniform number of cores allocated per die"
    end
  end

  describe "#update_spdk_version" do
    let(:vmh) {
      sshable = Sshable.create_with_id
      VmHost.create(location: "a") { _1.id = sshable.id }
    }

    before do
      expect(vm).to receive(:vm_host).and_return(vmh)
    end

    it "can update spdk version" do
      spdk_installation = SpdkInstallation.create(version: "b", allocation_weight: 100, vm_host_id: vmh.id) { _1.id = vmh.id }
      volume_dataset = instance_double(Sequel::Dataset)
      expect(vm).to receive(:vm_storage_volumes_dataset).and_return(volume_dataset)
      expect(volume_dataset).to receive(:update).with(spdk_installation_id: spdk_installation.id)
      expect(vm).to receive(:incr_update_spdk_dependency)

      vm.update_spdk_version("b")
    end

    it "fails if spdk installation not found" do
      expect { vm.update_spdk_version("b") }.to raise_error RuntimeError, "SPDK version b not found on host"
    end
  end

  describe "#utility functions" do
    it "can compute the ipv4 addresses" do
      as_ad = instance_double(AssignedVmAddress, ip: NetAddr::IPv4Net.new(NetAddr.parse_ip("1.1.1.0"), NetAddr::Mask32.new(32)))
      expect(vm).to receive(:assigned_vm_address).and_return(as_ad).at_least(:once)
      expect(vm.ephemeral_net4.to_s).to eq("1.1.1.0")
      expect(vm.ip4.to_s).to eq("1.1.1.0/32")
    end

    it "can compute nil if ipv4 is not assigned" do
      expect(vm.ephemeral_net4).to be_nil
    end
  end

  it "initiates a new health monitor session" do
    vh = instance_double(VmHost, sshable: instance_double(Sshable))
    expect(vm).to receive(:vm_host).and_return(vh).at_least(:once)
    expect(vh.sshable).to receive(:start_fresh_session)
    vm.init_health_monitor_session
  end

  it "checks pulse" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(vm).to receive(:inhost_name).and_return("vmxxxx").at_least(:once)
    expect(session[:ssh_session]).to receive(:exec!).and_return("active\nactive\n")
    expect(vm.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("up")

    expect(session[:ssh_session]).to receive(:exec!).and_return("active\ninactive\n")
    expect(vm).to receive(:reload).and_return(vm)
    expect(vm).to receive(:incr_checkup)
    expect(vm.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")

    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    expect(vm).to receive(:reload).and_return(vm)
    expect(vm).to receive(:incr_checkup)
    expect(vm.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end
end
