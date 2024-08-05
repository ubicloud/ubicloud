# frozen_string_literal: true

RSpec.describe Prog::Vnet::UpdateLoadBalancerNode do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create_with_id(prog: "Vnet::UpdateLoadBalancerNode", stack: [{"subject_id" => vm.id, "load_balancer_id" => lb.id}], label: "update_load_balancer")
  }
  let(:lb) {
    prj = Project.create_with_id(name: "test-prj").tap { _1.associate_with_project(_1) }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
    Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080).subject
  }
  let(:vm) {
    Prog::Vm::Nexus.assemble("pub-key", lb.projects.first.id, name: "test-vm", private_subnet_id: lb.private_subnet.id).subject
  }
  let(:neighbor_vm) {
    Prog::Vm::Nexus.assemble("pub-key", lb.projects.first.id, name: "neighbor-vm", private_subnet_id: lb.private_subnet.id).subject
  }

  before do
    lb.add_vm(vm)
    allow(nx).to receive_messages(vm: vm, load_balancer: lb)
    allow(vm).to receive_messages(ephemeral_net4: NetAddr::IPv4Net.parse("100.100.100.100/32"), ephemeral_net6: NetAddr::IPv6Net.parse("2a02:a464:deb2:a000::/64"))
  end

  describe "#update_load_balancer" do
    context "when no healthy vm exists" do
      it "hops to remove load balancer" do
        expect(lb).to receive(:active_vms).and_return([])
        expect { nx.update_load_balancer }.to hop("remove_load_balancer")
      end
    end

    context "when a single vm exists and it is the subject" do
      let(:vmh) {
        instance_double(VmHost, sshable: instance_double(Sshable))
      }

      before do
        lb.load_balancers_vms_dataset.update(state: "up")
        allow(vm).to receive(:vm_host).and_return(vmh)
      end

      it "does not hop to remove load balancer and creates basic load balancing with nat" do
        expect(lb).to receive(:active_vms).and_return([vm]).at_least(:once)
        expect(vm.nics.first).to receive(:private_ipv4).and_return(NetAddr::IPv4Net.parse("192.168.1.0/32")).at_least(:once)
        expect(vm.nics.first).to receive(:private_ipv6).and_return(NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fbb::/64")).at_least(:once)
        expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;

  }

  set neighbor_ips_v6 {
    type ipv6_addr;

  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 100.100.100.100/32 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 192.168.1.0 . 8080 }
    ip6 daddr 2a02:a464:deb2:a000::/64 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : fd10:9b0b:6b4b:8fbb::2 . 8080 }
    ip daddr 100.100.100.100/32 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr @neighbor_ips_v4 tcp dport 8080 ct state established,related,new counter snat to 192.168.1.0
    ip6 daddr @neighbor_ips_v6 tcp dport 8080 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100/32
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100/32
  }
}
LOAD_BALANCER
        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates basic load balancing with hashing" do
        lb.update(algorithm: "hash_based")
        expect(lb).to receive(:active_vms).and_return([vm]).at_least(:once)
        expect(vm.nics.first).to receive(:private_ipv4).and_return(NetAddr::IPv4Net.parse("192.168.1.0/32")).at_least(:once)
        expect(vm.nics.first).to receive(:private_ipv6).and_return(NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fbb::/64")).at_least(:once)
        expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;

  }

  set neighbor_ips_v6 {
    type ipv6_addr;

  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 100.100.100.100/32 tcp dport 80 ct state established,related,new counter dnat to jhash ip saddr . tcp sport . ip daddr . tcp dport mod 1 map { 0 : 192.168.1.0 . 8080 }
    ip6 daddr 2a02:a464:deb2:a000::/64 tcp dport 80 ct state established,related,new counter dnat to jhash ip6 saddr . tcp sport . ip6 daddr . tcp dport mod 1 map { 0 : fd10:9b0b:6b4b:8fbb::2 . 8080 }
    ip daddr 100.100.100.100/32 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr @neighbor_ips_v4 tcp dport 8080 ct state established,related,new counter snat to 192.168.1.0
    ip6 daddr @neighbor_ips_v6 tcp dport 8080 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100/32
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100/32
  }
}
LOAD_BALANCER
        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end
    end

    context "when multiple vms exist" do
      let(:vmh) {
        instance_double(VmHost, sshable: instance_double(Sshable))
      }

      before do
        allow(lb).to receive(:active_vms).and_return([vm, neighbor_vm]).at_least(:once)
        allow(vm).to receive(:vm_host).and_return(vmh)
        allow(vm.nics.first).to receive_messages(private_ipv4: NetAddr::IPv4Net.parse("192.168.1.0/32"), private_ipv6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fbb::/64"))
        allow(neighbor_vm.nics.first).to receive_messages(private_ipv4: NetAddr::IPv4Net.parse("172.10.1.0/32"), private_ipv6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:aaa::2/64"))
      end

      it "creates load balancing with multiple vms if all active" do
        expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;
elements = {172.10.1.0}
  }

  set neighbor_ips_v6 {
    type ipv6_addr;
elements = {fd10:9b0b:6b4b:aaa::2}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 100.100.100.100/32 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 2 map { 0 : 192.168.1.0 . 8080, 1 : 172.10.1.0 . 8080 }
    ip6 daddr 2a02:a464:deb2:a000::/64 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 2 map { 0 : fd10:9b0b:6b4b:8fbb::2 . 8080, 1 : fd10:9b0b:6b4b:aaa::2 . 8080 }
    ip daddr 100.100.100.100/32 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr @neighbor_ips_v4 tcp dport 8080 ct state established,related,new counter snat to 192.168.1.0
    ip6 daddr @neighbor_ips_v6 tcp dport 8080 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100/32
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100/32
  }
}
LOAD_BALANCER

        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates load balancing with multiple vms if the vm we work on is down" do
        expect(lb).to receive(:active_vms).and_return([neighbor_vm]).at_least(:once)
        expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;
elements = {172.10.1.0}
  }

  set neighbor_ips_v6 {
    type ipv6_addr;
elements = {fd10:9b0b:6b4b:aaa::2}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 100.100.100.100/32 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 172.10.1.0 . 8080 }
    ip6 daddr 2a02:a464:deb2:a000::/64 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : fd10:9b0b:6b4b:aaa::2 . 8080 }
    ip daddr 100.100.100.100/32 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr @neighbor_ips_v4 tcp dport 8080 ct state established,related,new counter snat to 192.168.1.0
    ip6 daddr @neighbor_ips_v6 tcp dport 8080 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100/32
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100/32
  }
}
LOAD_BALANCER

        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates load balancing with multiple vms if the vm we work on is up but the neighbor is down" do
        expect(lb).to receive(:active_vms).and_return([vm]).at_least(:once)
        expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;

  }

  set neighbor_ips_v6 {
    type ipv6_addr;

  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 100.100.100.100/32 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 192.168.1.0 . 8080 }
    ip6 daddr 2a02:a464:deb2:a000::/64 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : fd10:9b0b:6b4b:8fbb::2 . 8080 }
    ip daddr 100.100.100.100/32 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr @neighbor_ips_v4 tcp dport 8080 ct state established,related,new counter snat to 192.168.1.0
    ip6 daddr @neighbor_ips_v6 tcp dport 8080 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100/32
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100/32
  }
}
LOAD_BALANCER

        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "raises exception if the algorithm is not supported" do
        expect(lb).to receive(:algorithm).and_return("least_conn").at_least(:once)
        expect { nx.update_load_balancer }.to raise_error("Unsupported load balancer algorithm: least_conn")
      end
    end
  end

  describe "#remove_load_balancer" do
    let(:vmh) {
      instance_double(VmHost, sshable: instance_double(Sshable))
    }

    before do
      allow(vm).to receive(:vm_host).and_return(vmh)
      allow(vm.nics.first).to receive_messages(private_ipv4: NetAddr::IPv4Net.parse("192.168.1.0/32"), private_ipv6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fbb::/64"))
    end

    it "creates basic nat rules" do
      expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<REMOVE_LOAD_BALANCER)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 100.100.100.100/32 dnat to 192.168.1.0
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100/32
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100/32
  }
}
REMOVE_LOAD_BALANCER
      expect { nx.remove_load_balancer }.to exit({"msg" => "load balancer is updated"})
    end
  end

  it "returns load_balancer" do
    expect(nx).to receive(:load_balancer).and_call_original
    expect(nx.load_balancer.id).to eq(lb.id)
  end
end
