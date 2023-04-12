# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Nexus do
  subject(:nx) {
    described_class.new(st).tap { _1.instance_variable_set(:@vm, vm) }
  }

  let(:st) { Strand.new }
  let(:vm) { Vm.new(size: "m5a.2x") }
  let(:tg) { TagSpace.create(name: "default").tap { _1.associate_with_tag_space(_1) } }

  it "creates the user and key record" do
    private_subnets = [
      NetAddr::IPv6Net.parse("fd55:666:cd1a:ffff::/64"),
      NetAddr::IPv6Net.parse("fd12:345:6789:0abc::/64")
    ]
    st = described_class.assemble("some_ssh_key", tg.id, private_subnets: private_subnets)
    prog = described_class.new(st)
    vm = prog.vm
    vm.ephemeral_net6 = "fe80::/64"

    sshable = instance_spy(Sshable)
    vmh = instance_double(VmHost, sshable: sshable,
      total_cpus: 80, total_cores: 80, total_nodes: 1, total_sockets: 1)

    expect(st).to receive(:load).and_return(prog)
    expect(vm).to receive(:vm_host).and_return(vmh).at_least(:once)

    expect(sshable).to receive(:cmd).with(/echo (.|\n)* \| sudo -u vm[0-9a-z]+ tee/) do
      require "json"
      params = JSON(_1.shellsplit[1])
      expect(params["unix_user"]).to eq("ubi")
      expect(params["ssh_public_key"]).to eq("some_ssh_key")
      expect(params["public_ipv6"]).to eq("fe80::/64")
      expect(params["private_subnets"]).to include(*private_subnets.map { |s| s.to_s })
      expect(params["boot_image"]).to eq("ubuntu-jammy")
    end

    st.update(label: "prep")
    st.run
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
              total_mem_gib: 320}.merge(args)
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
