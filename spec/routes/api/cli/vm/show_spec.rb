# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm show" do
  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    @ref = [@vm.display_location, @vm.name].join("/")
    add_ipv4_to_vm(@vm, "128.0.0.1")
    subnet = @project.default_private_subnet(@vm.location)
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "#{@vm.name}-nic").subject
    nic.update(vm_id: @vm.id)
    @fw = subnet.firewalls.first
  end

  it "shows information for VM" do
    expect(cli(%W[vm #{@ref} show])).to eq <<~END
      id: #{@vm.ubid}
      name: test-vm
      state: running
      location: eu-central-h1
      size: standard-2
      unix-user: ubi
      storage-size-gib: 0
      ip6: 128:1234::2
      ip4-enabled: false
      ip4: 128.0.0.1
      private-ipv4: #{@vm.private_ipv4}
      private-ipv6: #{@vm.private_ipv6}
      subnet: default-eu-central-h1
      firewall 1:
        id: #{@fw.ubid}
        name: default-eu-central-h1-default
        description: Default firewall
        location: eu-central-h1
        path: /location/eu-central-h1/firewall/default-eu-central-h1-default
        rules:
          1: #{@fw.firewall_rules[0].ubid}  0.0.0.0/0  0..65535  
          2: #{@fw.firewall_rules[1].ubid}  ::/0  0..65535  
    END
  end

  it "-f option controls which fields are shown for VM" do
    expect(cli(%W[vm #{@ref} show -f id,name])).to eq <<~END
      id: #{@vm.ubid}
      name: test-vm
    END
  end

  it "-w option controls which fields are shown for VM's firewalls" do
    expect(cli(%W[vm #{@ref} show -f id,firewalls -w id,name])).to eq <<~END
      id: #{@vm.ubid}
      firewall 1:
        id: #{@fw.ubid}
        name: default-eu-central-h1-default
    END
  end

  it "-r option controls which fields are shown rules for VM's firewalls" do
    expect(cli(%W[vm #{@ref} show -f firewalls -w firewall-rules -r cidr,port-range])).to eq <<~END
      firewall 1:
        rules:
          1: 0.0.0.0/0  0..65535  
          2: ::/0  0..65535  
    END
  end
end
