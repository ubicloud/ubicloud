# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Vm do
  let(:project) { Project.create(name: "gcp-vm-test") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:vm) {
    create_vm(
      project_id: project.id,
      location_id: location.id,
      name: "gcp-test-vm",
      memory_gib: 8,
    )
  }

  context "with GCP provider" do
    describe "#ip6" do
      it "returns the first IPv6 address from ephemeral_net6" do
        vm.update(ephemeral_net6: "2600:1900:4000:1::1/128")
        expect(vm.ip6.to_s).to eq("2600:1900:4000:1::1")
      end

      it "returns nil when ephemeral_net6 is nil" do
        vm.update(ephemeral_net6: nil)
        expect(vm.ip6).to be_nil
      end
    end

    describe "#update_firewall_rules_prog" do
      it "returns the GCP UpdateFirewallRules prog class" do
        expect(vm.update_firewall_rules_prog).to eq(Prog::Vnet::Gcp::UpdateFirewallRules)
      end
    end

    describe "#add_vm_firewall GCP cap" do
      let(:gcp_ps) {
        PrivateSubnet.create(name: "gcp-ps", location_id: location.id, project_id: project.id,
          net6: "fd10:9b0b:6b4b:7f7f::/64", net4: "10.9.0.0/26", state: "active")
      }
      let(:gcp_vm) {
        v = create_vm(project_id: project.id, location_id: location.id, name: "gcp-vm")
        Nic.create(private_subnet_id: gcp_ps.id, vm_id: v.id, name: "nic-gcp",
          private_ipv4: gcp_ps.net4.nth(2).to_s,
          private_ipv6: gcp_ps.net6.nth(2).to_s,
          mac: "00:00:00:00:00:10", state: "active")
        v
      }

      def gcp_fw(suffix)
        Firewall.create(name: "vm-fw-#{suffix}", description: "d",
          location_id: location.id, project_id: project.id)
      end

      it "allows up to 9 VM-level firewalls on a GCP VM" do
        9.times { |i| gcp_vm.add_vm_firewall(gcp_fw(i)) }
        expect(gcp_vm.reload.vm_firewalls.count).to eq(9)
      end

      it "raises when a 10th firewall is added via add_vm_firewall on a GCP VM" do
        9.times { |i| gcp_vm.add_vm_firewall(gcp_fw(i)) }
        tenth = gcp_fw("extra")
        expect {
          gcp_vm.add_vm_firewall(tenth)
        }.to raise_error(Validation::ValidationFailed) { |e|
          expect(e.details[:firewall]).to match(/more than 9 firewalls/)
        }
        expect(gcp_vm.reload.vm_firewalls.count).to eq(9)
      end

      it "rejects a VM-level firewall when subnet firewalls already fill the cap" do
        9.times do |i|
          Firewall.create(name: "sub-fw-#{i}", description: "d",
            location_id: location.id, project_id: project.id)
            .associate_with_private_subnet(gcp_ps, apply_firewalls: false)
        end
        expect {
          gcp_vm.add_vm_firewall(gcp_fw("extra"))
        }.to raise_error(Validation::ValidationFailed)
      end

      it "allows VM-level firewalls on non-GCP VMs beyond the GCP cap" do
        hetzner_ps = PrivateSubnet.create(name: "hz-ps", location_id: Location::HETZNER_FSN1_ID,
          project_id: project.id, net6: "fd10:9b0b:6b4b:1fff::/64", net4: "10.8.0.0/26", state: "active")
        hz_vm = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "hz-vm")
        Nic.create(private_subnet_id: hetzner_ps.id, vm_id: hz_vm.id, name: "nic-hz",
          private_ipv4: hetzner_ps.net4.nth(2).to_s,
          private_ipv6: hetzner_ps.net6.nth(2).to_s,
          mac: "00:00:00:00:00:20", state: "active")
        10.times do |i|
          hz_vm.add_vm_firewall(Firewall.create(name: "hz-fw-#{i}", description: "d",
            location_id: Location::HETZNER_FSN1_ID, project_id: project.id))
        end
        expect(hz_vm.reload.vm_firewalls.count).to eq(10)
      end
    end
  end
end
