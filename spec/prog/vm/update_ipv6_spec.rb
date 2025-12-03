# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::UpdateIpv6 do
  subject(:pr) {
    described_class.new(Strand.new)
  }

  let(:vm) {
    instance_double(Vm,
      inhost_name: "test",
      storage_secrets: "storage_secrets",
      nics: [instance_double(Nic,
        private_subnet: instance_double(
          PrivateSubnet,
          net4: NetAddr::IPv4Net.parse("1.0.0.0/8")
        ),
        ubid_to_tap_name: "ubid_to_tap_name")],
      name: "test",
      vm_host_id: 1)
  }

  let(:vm_host) {
    instance_double(VmHost, sshable: create_mock_sshable(host: "1.1.1.1"), ip6_random_vm_network: NetAddr::IPv6Net.parse("2001:0::"))
  }

  before do
    allow(pr).to receive(:vm).and_return(vm)
  end

  it "returns vm_host" do
    expect(VmHost).to receive(:[]).with(1).and_return(vm_host)
    expect(pr.vm_host).to eq(vm_host)
  end

  it "stops services and cleans up namespace" do
    expect(vm).to receive(:load_balancer).and_return(instance_double(LoadBalancer, cert_enabled: true))
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl stop test.service")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl stop test-metadata-endpoint.service")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl stop test-dnsmasq.service")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo ip netns del test")
    expect(pr).to receive(:hop_rewrite_persisted)
    pr.start
  end

  it "does not stop metadata endpoint service if not load balancer" do
    expect(vm).to receive(:load_balancer).and_return(nil)
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl stop test.service")
    expect(vm_host.sshable).not_to receive(:_cmd).with("sudo systemctl stop test-metadata-endpoint.service")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl stop test-dnsmasq.service")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo ip netns del test")
    expect(pr).to receive(:hop_rewrite_persisted)
    pr.start
  end

  it "does not stop metadata endpoint service if load balancer is not cert enabled" do
    expect(vm).to receive(:load_balancer).and_return(instance_double(LoadBalancer, cert_enabled: false))
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl stop test.service")
    expect(vm_host.sshable).not_to receive(:_cmd).with("sudo systemctl stop test-metadata-endpoint.service")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl stop test-dnsmasq.service")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo ip netns del test")
    expect(pr).to receive(:hop_rewrite_persisted)
    pr.start
  end

  it "rewrites persisted" do
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm).to receive(:update).with(ephemeral_net6: "2001::/64")
    expect(pr).to receive(:write_params_json)
    expect(vm_host.sshable).to receive(:_cmd).with("sudo host/bin/setup-vm reassign-ip6 test", stdin: JSON.generate({storage: "storage_secrets"}))
    expect(pr).to receive(:hop_start_vm)
    pr.rewrite_persisted
  end

  it "starts vm" do
    expect(vm).to receive(:load_balancer).and_return(instance_double(LoadBalancer, cert_enabled: true))
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:_cmd).with("sudo ip -n test addr replace 1.0.0.1/8 dev ubid_to_tap_name")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo systemctl start test-metadata-endpoint.service")
    expect(vm).to receive(:incr_update_firewall_rules)
    expect(vm).to receive(:private_subnets).and_return([instance_double(PrivateSubnet, incr_refresh_keys: nil)])
    expect(pr).to receive(:pop).with("VM test updated")
    pr.start_vm
  end

  it "does not start metadata endpoint service if not load balancer" do
    expect(vm).to receive(:load_balancer).and_return(nil)
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:_cmd).with("sudo ip -n test addr replace 1.0.0.1/8 dev ubid_to_tap_name")
    expect(vm_host.sshable).not_to receive(:_cmd).with("sudo systemctl start test-metadata-endpoint.service")
    expect(vm).to receive(:incr_update_firewall_rules)
    expect(vm).to receive(:private_subnets).and_return([instance_double(PrivateSubnet, incr_refresh_keys: nil)])
    expect(pr).to receive(:pop).with("VM test updated")
    pr.start_vm
  end

  it "does not start metadata endpoint service if load balancer is not cert enabled" do
    expect(vm).to receive(:load_balancer).and_return(instance_double(LoadBalancer, cert_enabled: false))
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:_cmd).with("sudo ip -n test addr replace 1.0.0.1/8 dev ubid_to_tap_name")
    expect(vm_host.sshable).not_to receive(:_cmd).with("sudo systemctl start test-metadata-endpoint.service")
    expect(vm).to receive(:incr_update_firewall_rules)
    expect(vm).to receive(:private_subnets).and_return([instance_double(PrivateSubnet, incr_refresh_keys: nil)])
    expect(pr).to receive(:pop).with("VM test updated")
    pr.start_vm
  end

  it "writes params json" do
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm).to receive(:params_json).and_return("params_json")
    expect(vm).to receive(:strand).and_return(instance_double(Strand, stack: [{"gpu_count" => 0, "hugepages" => true, "ch_version" => nil, "gpu_device" => nil, "hypervisor" => nil, "force_host_id" => nil, "swap_size_bytes" => nil, "exclude_host_ids" => [], "firmware_version" => nil, "alternative_families" => [], "last_label_changed_at" => "2025-11-24 11:30:57 +0000", "distinct_storage_devices" => true}]))
    expect(vm_host.sshable).to receive(:_cmd).with("sudo rm /vm/test/prep.json")
    expect(vm_host.sshable).to receive(:_cmd).with("sudo -u test tee /vm/test/prep.json", stdin: "params_json")
    pr.write_params_json
  end
end
