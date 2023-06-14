# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Nexus do
  subject(:nx) {
    described_class.new(st).tap {
      _1.instance_variable_set(:@vm, vm)
    }
  }

  let(:st) { Strand.new }
  let(:vm) { Vm.new(size: "m5a.2x").tap { _1.id = "a410a91a-dc31-4119-9094-3c6a1fb49601" } }
  let(:tg) { TagSpace.create(name: "default").tap { _1.associate_with_tag_space(_1) } }

  describe ".assemble" do
    it "fails if there is no tagspace" do
      expect {
        described_class.assemble("some_ssh_key", "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "No existing tag space"
    end

    it "adds the VM to a private subnet if passed" do
      net = NetAddr.parse_net("fd10:9b0b:6b4b:8fbb::/64")
      expect {
        id = described_class.assemble("some_ssh_key", tg.id, private_subnets: [net]).id
        expect(VmPrivateSubnet[vm_id: id].private_subnet.cmp(net)).to eq 0
      }.to change(VmPrivateSubnet, :count).from(0).to 1
    end
  end

  describe "#create_unix_user" do
    let(:sshable) { instance_double(Sshable) }
    let(:vm_host) { instance_double(VmHost, sshable: sshable) }

    before do
      expect(vm).to receive(:vm_host).and_return(vm_host)
    end

    it "runs adduser" do
      expect(sshable).to receive(:cmd).with(/sudo.*adduser.*#{nx.vm_name}/)

      expect { nx.create_unix_user }.to raise_error Prog::Base::Hop do |hop|
        expect(hop.new_label).to eq("prep")
      end
    end

    it "absorbs an already-exists error as a success" do
      expect(sshable).to receive(:cmd).with(/sudo.*adduser.*#{nx.vm_name}/).and_raise(
        Sshable::SshError.new("adduser: The user `vmabc123' already exists.")
      )

      expect { nx.create_unix_user }.to raise_error Prog::Base::Hop do |hop|
        expect(hop.new_label).to eq("prep")
      end
    end

    it "raises other errors" do
      ex = Sshable::SshError.new("out of memory")
      expect(sshable).to receive(:cmd).with(/sudo.*adduser.*#{nx.vm_name}/).and_raise(ex)

      expect { nx.create_unix_user }.to raise_error ex
    end
  end

  describe "#prep" do
    it "generates and passes a params json" do
      vm = nx.vm
      vm.ephemeral_net6 = "fe80::/64"
      vm.unix_user = "test_user"
      vm.public_key = "test_ssh_key"
      expect(vm).to receive(:private_subnets).and_return [NetAddr.parse_net("fd10:9b0b:6b4b:8fbb::/64")]
      expect(vm).to receive(:cloud_hypervisor_cpu_topology).and_return(Vm::CloudHypervisorCpuTopo.new(1, 1, 1, 1))

      sshable = instance_spy(Sshable)
      vmh = instance_double(VmHost, sshable: sshable,
        total_cpus: 80, total_cores: 80, total_nodes: 1, total_sockets: 1, ndp_needed: false)
      expect(vm).to receive(:vm_host).and_return(vmh)

      expect(sshable).to receive(:cmd).with(/echo (.|\n)* \| sudo -u vm[0-9a-z]+ tee/) do
        require "json"
        params = JSON(_1.shellsplit[1])
        expect(params).to include({
          "public_ipv6" => "fe80::/64",
          "unix_user" => "test_user",
          "ssh_public_key" => "test_ssh_key",
          "max_vcpus" => 1,
          "cpu_topology" => "1:1:1:1",
          "mem_gib" => 4
        })
      end
      expect(sshable).to receive(:cmd).with(/sudo bin\/prepvm/)

      expect { nx.prep }.to raise_error Prog::Base::Hop do |hop|
        expect(hop.new_label).to eq("trigger_refresh_mesh")
      end
    end
  end

  describe "#start" do
    it "allocates the vm to a host" do
      vmh_id = "46ca6ded-b056-4723-bd91-612959f52f6f"
      vmh = VmHost.new(
        net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
        ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2")
      ) { _1.id = vmh_id }

      expect(nx).to receive(:allocate).and_return(vmh_id)
      expect(VmHost).to receive(:[]).with(vmh_id) { vmh }
      expect(vm).to receive(:update) do |**args|
        expect(args[:ephemeral_net6]).to match(/2a01:4f9:2b:35a:.*/)
        expect(args[:vm_host_id]).to match vmh_id
      end

      expect { nx.start }.to raise_error Prog::Base::Hop do |hop|
        expect(hop.new_label).to eq("create_unix_user")
      end
    end
  end

  describe "#allocate" do
    before do
      @host_index = 0
      vm.location = "somewhere-normal"
    end

    def new_host(**args)
      args = {allocation_state: "accepting",
              location: "somewhere-normal",
              total_sockets: 1,
              total_nodes: 4,
              total_cores: 80,
              total_cpus: 80,
              total_mem_gib: 320,
              total_hugepages_1g: 316}.merge(args)
      sa = Sshable.create(host: "127.0.0.#{@host_index}")
      @host_index += 1
      VmHost.new(**args) { _1.id = sa.id }
    end

    it "fails if there are no VmHosts" do
      expect { nx.allocate }.to raise_error RuntimeError, "no space left on any eligible hosts"
    end

    it "only matches when location matches" do
      vm.location = "somewhere-normal"
      vmh = new_host(location: "somewhere-weird").save_changes
      expect { nx.allocate }.to raise_error RuntimeError, "no space left on any eligible hosts"

      vm.location = "somewhere-weird"
      expect(nx.allocate).to eq vmh.id
      expect(vmh.reload.used_cores).to eq(1)
    end

    it "does not match if there is not enough ram capacity" do
      new_host(total_mem_gib: 1).save_changes
      expect { nx.allocate }.to raise_error RuntimeError, "no space left on any eligible hosts"
    end

    it "prefers the host with a more snugly fitting RAM ratio, even if busy" do
      snug = new_host(used_cores: 78).save_changes
      new_host(total_mem_gib: 640).save_changes
      expect(nx.allocation_dataset.map { _1[:mem_ratio] }).to eq([4, 8])
      expect(nx.allocate).to eq snug.id
    end

    it "prefers hosts with fewer used cores" do
      idle = new_host.save_changes
      new_host(used_cores: 70).save_changes
      expect(nx.allocation_dataset.map { _1[:used_cores] }).to eq([0, 70])
      expect(nx.allocate).to eq idle.id
    end
  end
end
