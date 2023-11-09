# frozen_string_literal: true

RSpec.describe Prog::Vnet::UpdateFirewallRules do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    instance_double(PrivateSubnet)
  }
  let(:vm) {
    vmh = instance_double(VmHost, sshable: instance_double(Sshable, cmd: nil))
    instance_double(Vm, private_subnets: [ps], vm_host: vmh, inhost_name: "x")
  }

  describe "update_firewall_rules" do
    it "populates elements if there are fw rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(ps).to receive(:firewall_rules).and_return([
        instance_double(FirewallRule, ip6?: false, ip: "0.0.0.0/0"),
        instance_double(FirewallRule, ip6?: false, ip: "1.1.1.1/32"),
        instance_double(FirewallRule, ip6?: true, ip: "::/0"),
        instance_double(FirewallRule, ip6?: true, ip: "fd00::1/128")
      ])
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
flush set inet fw_table allowed_ipv4_ips;
flush set inet fw_table allowed_ipv6_ips;
table inet fw_table {
  set allowed_ipv4_ips {
    type ipv4_addr;
    flags interval;
elements = {0.0.0.0/0,1.1.1.1/32}
  }

  set allowed_ipv6_ips {
    type ipv6_addr;
    flags interval;
elements = {::/0,fd00::1/128}
  }
}
ADD_RULES

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pass elements if there are not fw rules" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(ps).to receive(:firewall_rules).and_return([])
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ip netns exec x nft --file -", stdin: <<ADD_RULES)
flush set inet fw_table allowed_ipv4_ips;
flush set inet fw_table allowed_ipv6_ips;
table inet fw_table {
  set allowed_ipv4_ips {
    type ipv4_addr;
    flags interval;

  }

  set allowed_ipv6_ips {
    type ipv6_addr;
    flags interval;

  }
}
ADD_RULES

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
