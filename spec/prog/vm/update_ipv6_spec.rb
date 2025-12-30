# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::UpdateIpv6 do
  subject(:pr) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-project") }
  let(:sshable) { pr.vm_host.sshable }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    ps = PrivateSubnet.create(
      name: "test-subnet", project_id: project.id, location_id:,
      net4: "1.0.0.0/8", net6: "fd10:9b0b:6b4b:8fbb::/64"
    )
    Strand.create_with_id(ps, prog: "Vnet::SubnetNexus", label: "wait")
    ps
  }

  let(:vm_host) {
    create_vm_host(
      location_id:,
      total_cpus: 48, total_cores: 48, total_dies: 1, total_sockets: 1,
      net6: NetAddr::IPv6Net.parse("2001:db8::/48")
    )
  }

  let(:vm_strand) {
    Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "test", private_subnet_id: private_subnet.id,
      location_id:, force_host_id: vm_host.id
    )
  }

  let(:vm) {
    v = vm_strand.subject
    v.update(vm_host_id: vm_host.id)
    v
  }

  let(:strand) {
    Strand.create(
      prog: "Vm::UpdateIpv6", label: "start",
      parent_id: vm_strand.id,
      stack: [
        {"subject_id" => vm.id, "gpu_count" => 0, "hugepages" => true, "ch_version" => nil,
         "gpu_device" => nil, "hypervisor" => nil, "force_host_id" => nil, "swap_size_bytes" => nil,
         "exclude_host_ids" => [], "firmware_version" => nil, "alternative_families" => [],
         "last_label_changed_at" => Time.now.to_s, "distinct_storage_devices" => true}
      ]
    )
  }

  def create_load_balancer(cert_enabled:)
    lb = LoadBalancer.create(
      name: "test-lb", private_subnet_id: private_subnet.id, project_id: project.id,
      health_check_endpoint: "/health", cert_enabled:
    )
    LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm.id)
    lb
  end

  it "returns vm_host" do
    expect(pr.vm_host.id).to eq(vm_host.id)
  end

  it "stops services and cleans up namespace" do
    create_load_balancer(cert_enabled: true)
    inhost_name = vm.inhost_name
    expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{inhost_name}.service")
    expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{inhost_name}-metadata-endpoint.service")
    expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{inhost_name}-dnsmasq.service")
    expect(sshable).to receive(:_cmd).with("sudo ip netns del #{inhost_name}")
    expect { pr.start }.to hop("rewrite_persisted")
  end

  it "does not stop metadata endpoint service if not load balancer" do
    inhost_name = vm.inhost_name
    expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{inhost_name}.service")
    expect(sshable).not_to receive(:_cmd).with(/metadata-endpoint/)
    expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{inhost_name}-dnsmasq.service")
    expect(sshable).to receive(:_cmd).with("sudo ip netns del #{inhost_name}")
    expect { pr.start }.to hop("rewrite_persisted")
  end

  it "does not stop metadata endpoint service if load balancer is not cert enabled" do
    create_load_balancer(cert_enabled: false)
    inhost_name = vm.inhost_name
    expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{inhost_name}.service")
    expect(sshable).not_to receive(:_cmd).with(/metadata-endpoint/)
    expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{inhost_name}-dnsmasq.service")
    expect(sshable).to receive(:_cmd).with("sudo ip netns del #{inhost_name}")
    expect { pr.start }.to hop("rewrite_persisted")
  end

  it "rewrites persisted" do
    inhost_name = vm.inhost_name
    expect(sshable).to receive(:_cmd).with("sudo rm /vm/#{inhost_name}/prep.json")
    expect(sshable).to receive(:_cmd) do |cmd, **kwargs|
      expect(cmd).to eq("sudo -u #{inhost_name} tee /vm/#{inhost_name}/prep.json")
      expect(kwargs[:stdin]).to include('"vm_name": "test"')
    end
    expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm reassign-ip6 #{inhost_name}", stdin: JSON.generate({storage: vm.storage_secrets}))
    expect { pr.rewrite_persisted }.to hop("start_vm")
    net6 = vm.reload.ephemeral_net6
    expect(net6.to_s).to start_with("2001:db8:")
    expect(net6.netmask.prefix_len).to eq(63)
  end

  it "starts vm" do
    create_load_balancer(cert_enabled: true)
    inhost_name = vm.inhost_name
    nic = vm.nics.first
    addr = nic.private_subnet.net4.nth(1).to_s + nic.private_subnet.net4.netmask.to_s
    expect(sshable).to receive(:_cmd).with("sudo ip -n #{inhost_name} addr replace #{addr} dev #{nic.ubid_to_tap_name}")
    expect(sshable).to receive(:_cmd).with("sudo systemctl start #{inhost_name}-metadata-endpoint.service")
    expect { pr.start_vm }.to exit({"msg" => "VM test updated"})
    expect(vm.reload.update_firewall_rules_set?).to be true
    expect(private_subnet.reload.refresh_keys_set?).to be true
  end

  it "does not start metadata endpoint service if not load balancer" do
    inhost_name = vm.inhost_name
    nic = vm.nics.first
    addr = nic.private_subnet.net4.nth(1).to_s + nic.private_subnet.net4.netmask.to_s
    expect(sshable).to receive(:_cmd).with("sudo ip -n #{inhost_name} addr replace #{addr} dev #{nic.ubid_to_tap_name}")
    expect(sshable).not_to receive(:_cmd).with(/metadata-endpoint/)
    expect { pr.start_vm }.to exit({"msg" => "VM test updated"})
    expect(vm.reload.update_firewall_rules_set?).to be true
    expect(private_subnet.reload.refresh_keys_set?).to be true
  end

  it "does not start metadata endpoint service if load balancer is not cert enabled" do
    create_load_balancer(cert_enabled: false)
    inhost_name = vm.inhost_name
    nic = vm.nics.first
    addr = nic.private_subnet.net4.nth(1).to_s + nic.private_subnet.net4.netmask.to_s
    expect(sshable).to receive(:_cmd).with("sudo ip -n #{inhost_name} addr replace #{addr} dev #{nic.ubid_to_tap_name}")
    expect(sshable).not_to receive(:_cmd).with(/metadata-endpoint/)
    expect { pr.start_vm }.to exit({"msg" => "VM test updated"})
    expect(vm.reload.update_firewall_rules_set?).to be true
    expect(private_subnet.reload.refresh_keys_set?).to be true
  end

  it "writes params json" do
    inhost_name = vm.inhost_name
    expect(sshable).to receive(:_cmd).with("sudo rm /vm/#{inhost_name}/prep.json")
    expect(sshable).to receive(:_cmd) do |cmd, **kwargs|
      expect(cmd).to eq("sudo -u #{inhost_name} tee /vm/#{inhost_name}/prep.json")
      expect(kwargs[:stdin]).to include('"vm_name": "test"')
    end
    pr.write_params_json
  end
end
