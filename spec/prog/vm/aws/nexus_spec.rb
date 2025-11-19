# frozen_string_literal: true

require_relative "../../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Aws::Nexus do
  subject(:nx) {
    described_class.new(vm.strand).tap {
      it.instance_variable_set(:@vm, vm)
    }
  }

  let(:st) { vm.strand }
  let(:vm_host) { create_vm_host(used_cores: 2, total_hugepages_1g: 375, used_hugepages_1g: 16) }
  let(:sshable) { vm_host.sshable }
  let(:location) { Location.create(name: "us-west-2-test", provider: "aws", project_id: project.id, display_name: "us-west-2-test", ui_name: "us-west-2-test", visible: true) }
  let(:vm) {
    vm = Vm.create_with_id(
      "2464de61-7501-8374-9ab0-416caebe31da",
      name: "dummy-vm",
      unix_user: "ubi",
      public_key: "ssh key",
      boot_image: "ubuntu-jammy",
      family: "standard",
      cores: 1,
      vcpus: 2,
      cpu_percent_limit: 200,
      cpu_burst_percent_limit: 0,
      memory_gib: 8,
      arch: "x64",
      location_id: location.id,
      created_at: Time.now,
      project_id: project.id,
      vm_host_id: vm_host.id
    )
    Strand.create_with_id(vm.id, prog: "Vm::Aws::Nexus", label: "start")
    vm
  }
  let(:project) { Project.create(name: "default") }
  let(:private_subnet) {
    PrivateSubnet.create(name: "ps", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: project.id)
  }
  let(:nic) {
    Nic.create(private_subnet_id: private_subnet.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
      private_ipv4: "10.0.0.1",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic",
      state: "active")
  }

  describe "#start" do
    it "naps if vm nics are not in wait state" do
      nic.update(vm_id: vm.id)
      Strand.create_with_id(nic.id, prog: "Vnet::NicNexus", label: "start")
      expect { nx.start }.to nap(1)
    end

    it "hops to wait_aws_vm_started if vm nics are in wait state" do
      st.stack = [{"alternative_families" => ["m7i", "m6a"]}]
      nic.update(vm_id: vm.id)
      Strand.create_with_id(nic.id, prog: "Vnet::NicNexus", label: "wait")
      expect(nx).to receive(:bud).with(Prog::Aws::Instance, {"subject_id" => vm.id, "alternative_families" => ["m7i", "m6a"]}, :start)
      expect { nx.start }.to hop("wait_aws_vm_started")
    end
  end

  describe "#wait_aws_vm_started" do
    it "reaps and naps if not leaf" do
      Strand.create(parent_id: st.id, prog: "Aws::Instance", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_aws_vm_started }.to nap(3)
    end

    it "hops to wait_sshable if leaf" do
      expect { nx.wait_aws_vm_started }.to hop("wait_sshable")
    end
  end

  describe "#wait_sshable" do
    it "naps 6 seconds if it's the first time we execute wait_sshable" do
      expect { nx.wait_sshable }.to nap(6)
        .and change { vm.reload.update_firewall_rules_set? }.from(false).to(true)
    end

    it "naps if not sshable" do
      expect(vm).to receive(:ip4).and_return(NetAddr::IPv4.parse("10.0.0.1"))
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      vm.incr_update_firewall_rules
      adr = Address.create(cidr: "10.0.0.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "10.0.0.1", address_id: adr.id, dst_vm_id: vm.id)
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end

    it "skips a check if ipv4 is not enabled" do
      vm.incr_update_firewall_rules
      expect(vm.ip4).to be_nil
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end
  end

  describe "#create_billing_record" do
    let(:now) { Time.now }

    before do
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      vm.update(allocated_at: now - 100)
      expect(vm).to receive(:aws_instance).and_return(instance_double(AwsInstance, instance_id: "i-0123456789abcdefg"))
      expect(Clog).to receive(:emit).with("vm provisioned").and_yield
    end

    it "not create billing records when the project is not billable" do
      project.update(billable: false)
      expect { nx.create_billing_record }.to hop("wait")
      expect(BillingRecord.count).to eq(0)
    end

    it "creates billing records for only vm" do
      expect(vm.location).to receive(:name).and_return("us-west-2")
      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(1)
      expect(vm.active_billing_records.first.billing_rate["resource_type"]).to eq("VmVCpu")
      expect(vm.display_state).to eq("running")
      expect(vm.provisioned_at).to eq(now)
    end

    it "doesn't create additional billing records when the location provider is aws" do
      expect(vm.location).to receive(:name).and_return("us-west-2")
      vm.ip4_enabled = true
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, skip_sync: false)
      adr = Address.create(cidr: "192.168.1.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)
      PciDevice.create(vm_id: vm.id, vm_host_id: vm_host.id, slot: "01:00.0", iommu_group: 23, device_class: "0302", vendor: "10de", device: "20b5")

      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(1)
      expect(vm.active_billing_records.first.billing_rate["resource_type"]).to eq("VmVCpu")
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      vm.incr_destroy
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      ["destroy", "wait_aws_vm_destroyed"].each do |label|
        vm.incr_destroy
        st.label = label
        expect { nx.before_run }.not_to hop("destroy")
      end
    end

    it "stops billing before hops to destroy" do
      expect(vm.location).to receive(:name).and_return("us-west-2").at_least(:once)
      adr = Address.create(cidr: "192.168.1.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)

      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
        amount: vm.vcpus
      )

      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.assigned_vm_address.id,
        resource_name: vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", vm.location.name)["id"],
        amount: 1
      )

      vm.incr_destroy
      vm.active_billing_records.each { expect(it).to receive(:finalize).and_call_original }
      expect(vm.assigned_vm_address.active_billing_record).to receive(:finalize).and_call_original
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found" do
      vm.incr_destroy
      expect(vm.active_billing_records).to be_empty
      expect(vm.assigned_vm_address).to be_nil
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found for ipv4" do
      vm.incr_destroy
      adr = Address.create(cidr: "192.168.1.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)
      expect(vm.assigned_vm_address).not_to be_nil
      expect(vm.assigned_vm_address.active_billing_record).to be_nil

      expect { nx.before_run }.to hop("destroy")
    end
  end

  describe "#wait" do
    it "naps when nothing to do" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to update_firewall_rules when needed" do
      vm.incr_update_firewall_rules
      expect { nx.wait }.to hop("update_firewall_rules")
    end
  end

  describe "#update_firewall_rules" do
    it "hops to wait_firewall_rules" do
      vm.incr_update_firewall_rules
      expect(vm).to receive(:location).and_return(instance_double(Location, aws?: true))
      expect(nx).to receive(:push).with(Prog::Vnet::Aws::UpdateFirewallRules, {}, :update_firewall_rules)
      expect { nx.update_firewall_rules }
        .to change { vm.reload.update_firewall_rules_set? }.from(true).to(false)
    end

    it "hops to wait if firewall rules are applied" do
      expect(nx).to receive(:retval).and_return({"msg" => "firewall rule is added"})
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#prevent_destroy" do
    it "registers a deadline and naps while preventing" do
      expect(nx).to receive(:register_deadline)
      expect { nx.prevent_destroy }.to nap(30)
    end
  end

  describe "#destroy" do
    it "prevents destroy if the semaphore set" do
      vm.incr_prevent_destroy
      expect(Clog).to receive(:emit).with("Destroy prevented by the semaphore").and_call_original
      expect { nx.destroy }.to hop("prevent_destroy")
    end

    it "hops to wait_aws_vm_destroyed" do
      location_id = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true).id
      vm.update(location_id:)
      st.update(prog: "Vm::Nexus", label: "destroy", stack: [{}])
      child = Strand.create(parent_id: st.id, prog: "Aws::Instance", label: "start", stack: [{}])
      expect(nx).to receive(:bud).with(Prog::Aws::Instance, {"subject_id" => vm.id}, :destroy)
      expect { nx.destroy }.to hop("wait_aws_vm_destroyed")
      expect(Semaphore[strand_id: child.id, name: "destroy"]).not_to be_nil
      expect(vm.display_state).to eq("deleting")
    end
  end

  describe "#final_clean_up" do
    it "detaches from nic" do
      nic.update(vm_id: vm.id)
      Strand.create_with_id(nic.id, prog: "Vnet::NicNexus", label: "start")
      nx.final_clean_up
      expect(nic.reload.destroy_set?).to be(true)
      expect(nic.vm_id).to be_nil
      expect(vm.exists?).to be(false)
    end
  end

  describe "#wait_aws_vm_destroyed" do
    it "reaps and pops if leaf" do
      st.update(prog: "Vm::Nexus", label: "wait_aws_vm_destroyed", stack: [{}])
      expect(nx).to receive(:final_clean_up)
      expect { nx.wait_aws_vm_destroyed }.to exit({"msg" => "vm deleted"})
    end

    it "naps if not leaf" do
      st.update(prog: "Vm::Nexus", label: "wait_aws_vm_destroyed", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Aws::Instance", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_aws_vm_destroyed }.to nap(10)
    end
  end
end
