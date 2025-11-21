# frozen_string_literal: true

RSpec.describe Prog::Vnet::UpdateLoadBalancerNode do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create(prog: "Vnet::UpdateLoadBalancerNode", stack: [{"subject_id" => vm.id, "load_balancer_id" => lb.id}], label: "update_load_balancer")
  }
  let(:prj) {
    Project.create(name: "test-prj")
  }
  let(:ps) {
    Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
  }

  let(:lb) {
    lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080).subject
    dz = DnsZone.create(name: "test-dns-zone", project_id: prj.id)
    cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    lb.add_cert(cert)
    lb
  }
  let(:vm) {
    nic = Prog::Vnet::NicNexus.assemble(ps.id, ipv4_addr: "192.168.1.0/32", ipv6_addr: "fd10:9b0b:6b4b:8fbb::/64").subject
    Prog::Vm::Nexus.assemble("pub key", lb.project_id, name: "vm1", private_subnet_id: lb.private_subnet.id, nic_id: nic.id).subject
  }
  let(:neighbor_vm) {
    nic = Prog::Vnet::NicNexus.assemble(ps.id, ipv4_addr: "172.10.1.0/32", ipv6_addr: "fd10:9b0b:6b4b:aaa::/64").subject
    Prog::Vm::Nexus.assemble("pub key", lb.project_id, name: "vm2", private_subnet_id: lb.private_subnet.id, nic_id: nic.id).subject
  }
  let(:vmh) {
    vmh = instance_double(VmHost, sshable: Sshable.new)
    allow(vm).to receive(:vm_host).and_return(vmh)
    vmh
  }

  before do
    lb.add_vm(vm)
    allow(nx).to receive_messages(vm: vm, load_balancer: lb)
    allow(vm).to receive_messages(ip4: NetAddr::IPv4.parse("100.100.100.100"), ip6: NetAddr::IPv6.parse("2a02:a464:deb2:a000::2"))
    allow(vm).to receive(:vm_host).and_return(instance_double(VmHost, sshable: Sshable.new))
  end

  describe ".before_run" do
    it "simply pops if VM is destroyed" do
      expect(nx).to receive(:vm).and_return(nil)

      expect { nx.before_run }.to exit({"msg" => "VM is destroyed"})
    end

    it "pops if destroy semaphore is set" do
      nx.incr_destroy

      expect { nx.before_run }.to exit({"msg" => "early exit due to destroy semaphore"})
    end

    it "doesn't do anything if the VM is not destroyed" do
      expect(nx).to receive(:vm).and_return(vm)

      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_load_balancer" do
    context "when no healthy vm exists" do
      it "hops to remove load balancer" do
        expect(lb).to receive(:active_vm_ports).and_return([])
        expect { nx.update_load_balancer }.to hop("remove_load_balancer")
      end

      it "removes the VM from load balancer if the VM is detaching" do
        LoadBalancerVmPort.dataset.update(state: "detaching")
        expect(lb).to receive(:remove_vm_port).with(lb.vm_ports_dataset.find { |lvp| lvp.stack == "ipv4" })
        expect(lb).to receive(:remove_vm_port).with(lb.vm_ports_dataset.find { |lvp| lvp.stack == "ipv6" })
        expect { nx.update_load_balancer }.to hop("remove_load_balancer")
      end
    end

    context "when a single vm exists and it is the subject" do
      before do
        LoadBalancerVmPort.where(id: lb.vm_ports_dataset.map(&:id)).update(state: "up")
      end

      it "does not hop to remove load balancer and creates basic load balancing with nat" do
        expect(vmh.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 192.168.1.0 . 8080 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 2a02:a464:deb2:a000::2 . 8080 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 80 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8080


    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0
ip6 daddr @neighbor_ips_v6 tcp dport 80 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2

    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER
        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "does not hop to remove load balancer and creates basic load balancing with nat specifically for ipv4" do
        lb.update(stack: "ipv4")
        expect(vmh.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 192.168.1.0 . 8080 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080



    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0


    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER
        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates basic load balancing with hashing with multiple ports" do
        lb.add_port(443, 8443)
        lb.reload
        port = LoadBalancerPort.where(load_balancer_id: lb.id, src_port: 443).first
        LoadBalancerVmPort.where(load_balancer_port_id: port.id).update(state: "up")
        expect(vmh.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 192.168.1.0 . 8080 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080

ip daddr 100.100.100.100 tcp dport 443 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 443 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 192.168.1.0 . 8443 }
ip daddr 192.168.1.0 tcp dport 443 ct state established,related,new counter dnat to 192.168.1.0:8443

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 2a02:a464:deb2:a000::2 . 8080 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 80 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8080

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 443 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 443 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 2a02:a464:deb2:a000::2 . 8443 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 443 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8443


    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0
ip daddr @neighbor_ips_v4 tcp dport 443 ct state established,related,new counter snat to 192.168.1.0
ip6 daddr @neighbor_ips_v6 tcp dport 80 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2
ip6 daddr @neighbor_ips_v6 tcp dport 443 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2

    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER
        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates basic load balancing with hashing" do
        lb.update(algorithm: "hash_based")
        expect(vmh.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to jhash ip saddr . tcp sport . ip daddr . tcp dport mod 1 map { 0 : 192.168.1.0 . 8080 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 ct state established,related,new counter dnat to jhash ip6 saddr . tcp sport . ip6 daddr . tcp dport mod 1 map { 0 : 2a02:a464:deb2:a000::2 . 8080 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 80 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8080


    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0
ip6 daddr @neighbor_ips_v6 tcp dport 80 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2

    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER
        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end
    end

    context "when multiple vms exist" do
      before do
        lb.add_vm(neighbor_vm)
        LoadBalancerVmPort.map { |lbvmport| lbvmport.update(state: "up") }
      end

      it "creates load balancing with multiple vms if all active" do
        expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 2 map { 0 : 172.10.1.0 . 80, 1 : 192.168.1.0 . 8080 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 2 map { 0 : 2a02:a464:deb2:a000::2 . 8080, 1 : fd10:9b0b:6b4b:aaa::2 . 80 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 80 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8080


    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0
ip6 daddr @neighbor_ips_v6 tcp dport 80 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2

    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER

        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates load balancing with multiple vms if all active ipv6 only" do
        lb.update(stack: "ipv6")
        LoadBalancerVmPort.where(stack: "ipv4").destroy
        expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
elements = {fd10:9b0b:6b4b:aaa::2}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 2 map { 0 : 2a02:a464:deb2:a000::2 . 8080, 1 : fd10:9b0b:6b4b:aaa::2 . 80 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 80 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8080


    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

ip6 daddr @neighbor_ips_v6 tcp dport 80 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2

    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER

        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates load balancing with multiple vms if all active ipv4 only" do
        lb.update(stack: "ipv4")
        LoadBalancerVmPort.where(stack: "ipv6").destroy
        expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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

  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 2 map { 0 : 172.10.1.0 . 80, 1 : 192.168.1.0 . 8080 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080



    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0


    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER

        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates load balancing with multiple vms if the vm we work on is down" do
        LoadBalancerVmPort.where(load_balancer_vm_id: vm.load_balancer_vm.id).update(state: "down")
        expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 172.10.1.0 . 80 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : fd10:9b0b:6b4b:aaa::2 . 80 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 80 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8080


    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0
ip6 daddr @neighbor_ips_v6 tcp dport 80 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2

    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
LOAD_BALANCER

        expect { nx.update_load_balancer }.to exit({"msg" => "load balancer is updated"})
      end

      it "creates load balancing with multiple vms if the vm we work on is up but the neighbor is down" do
        LoadBalancerVmPort.where(load_balancer_vm_id: neighbor_vm.load_balancer_vm.id).update(state: "down")
        expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<LOAD_BALANCER)
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
ip daddr 100.100.100.100 tcp dport 80 meta mark set 0x00B1C100D
ip daddr 100.100.100.100 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 192.168.1.0 . 8080 }
ip daddr 192.168.1.0 tcp dport 80 ct state established,related,new counter dnat to 192.168.1.0:8080

ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 meta mark set 0x00B1C100D
ip6 daddr 2a02:a464:deb2:a000::2 tcp dport 80 ct state established,related,new counter dnat to numgen inc mod 1 map { 0 : 2a02:a464:deb2:a000::2 . 8080 }
ip6 daddr fd10:9b0b:6b4b:8fbb::2 tcp dport 80 ct state established,related,new counter dnat to [2a02:a464:deb2:a000::2]:8080


    # Basic NAT for public IPv4 to private IPv4
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
ip daddr @neighbor_ips_v4 tcp dport 80 ct state established,related,new counter snat to 192.168.1.0
ip6 daddr @neighbor_ips_v6 tcp dport 80 ct state established,related,new counter snat to fd10:9b0b:6b4b:8fbb::2

    # Basic NAT for private IPv4 to public IPv4
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
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
    it "creates basic nat rules" do
      expect(vmh.sshable).to receive(:_cmd).with("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: <<REMOVE_LOAD_BALANCER)
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 100.100.100.100 dnat to 192.168.1.0
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 192.168.1.0 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 100.100.100.100
    ip saddr 192.168.1.0 ip daddr 192.168.1.0 snat to 100.100.100.100
  }
}
REMOVE_LOAD_BALANCER
      expect { nx.remove_load_balancer }.to exit({"msg" => "load balancer is removed"})
    end
  end

  it "returns load_balancer" do
    expect(nx).to receive(:load_balancer).and_call_original
    expect(nx.load_balancer.id).to eq(lb.id)
  end
end
