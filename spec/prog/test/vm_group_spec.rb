# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VmGroup do
  subject(:vg_test) { described_class.new(st) }

  let(:st) { described_class.assemble(boot_images: ["ubuntu-noble", "debian-12"]) }
  let(:prj) { Project.create(name: "project-1") }
  let(:ps1) {
    Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps1", location_id: Location::HETZNER_FSN1_ID).subject
  }
  let(:ps2) {
    Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID).subject
  }

  describe "#start" do
    it "hops to setup_vms" do
      expect { vg_test.start }.to hop("setup_vms")
    end
  end

  describe "#setup_vms" do
    it "hops to wait_children_ready" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[it].boot_image }
      expect(vm_images).to eq(["ubuntu-noble", "debian-12", "ubuntu-noble"])
    end

    it "provisions at least one vm for each boot image" do
      expect(vg_test).to receive(:update_stack).and_call_original
      refresh_frame(vg_test, new_values: {
        "test_slices" => true,
        "boot_images" => ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]
      })
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[it].boot_image }
      expect(vm_images).to eq(["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"])
    end

    it "hops to wait_children_ready if test_slices" do
      expect(vg_test).to receive(:update_stack).and_call_original
      refresh_frame(vg_test, new_values: {
        "test_reboot" => true,
        "test_slices" => true,
        "vms" => [],
        "boot_images" => ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]
      })
      expect { vg_test.setup_vms }.to hop("wait_vms")
    end
  end

  describe "#wait_vms" do
    it "hops to verify_vms if vms are ready" do
      vm = create_vm(display_state: "running")
      refresh_frame(vg_test, new_values: {"vms" => [vm.id]})
      expect { vg_test.wait_vms }.to hop("verify_vms")
    end

    it "naps if vms are not running" do
      vm = create_vm(display_state: "creating")
      refresh_frame(vg_test, new_values: {"vms" => [vm.id]})
      expect { vg_test.wait_vms }.to nap(10)
    end
  end

  describe "#verify_vms" do
    it "runs tests for the first vm" do
      vm1 = create_vm(name: "test-vm-1")
      vm2 = create_vm(name: "test-vm-2")
      refresh_frame(vg_test, new_values: {"vms" => [vm1.id, vm2.id], "first_boot" => true})
      expect { vg_test.verify_vms }.to hop("wait_verify_vms")
      children = st.children_dataset.where(prog: "Test::Vm").all
      expect(children.map { it.stack.first.values_at("subject_id", "first_boot") }).to contain_exactly([vm1.id, true], [vm2.id, true])
    end
  end

  describe "#wait_verify_vms" do
    it "hops to hop_wait_verify_vms" do
      expect { vg_test.wait_verify_vms }.to hop("verify_host_capacity")
    end

    it "stays in wait_verify_vms" do
      Strand.create(parent_id: st.id, prog: "Test::Vm", label: "start", stack: [{}], lease: Time.now + 10)
      expect { vg_test.wait_verify_vms }.to nap(120)

      expect(st).to receive(:lock!).and_wrap_original do |m|
        # Pretend child strand updated schedule before lock.
        # After the lock, shouldn't be possible as the child
        # strand's update of the parent will block until
        # parent strand commits.
        st.this.update(schedule: Time.now - 1)
        m.call
      end
      expect { vg_test.wait_verify_vms }.to nap(0)
    end
  end

  describe "#verify_host_capacity" do
    it "hops to verify_vm_host_slices" do
      vm_host = create_vm_host(total_cpus: 16, total_cores: 8, used_cores: 3)
      vm1 = create_vm(vm_host_id: vm_host.id, cores: 2, name: "test-vm-1")
      create_vm(vm_host_id: vm_host.id, cores: 0, name: "test-vm-2")
      create_vm_host_slice(vm_host_id: vm_host.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm1.id], "verify_host_capacity" => true})
      expect { vg_test.verify_host_capacity }.to hop("verify_vm_host_slices")
    end

    it "skips if verify_host_capacity is not set" do
      refresh_frame(vg_test, new_values: {"verify_host_capacity" => false})
      expect(vg_test).not_to receive(:vm_host)
      expect { vg_test.verify_host_capacity }.to hop("verify_vm_host_slices")
    end

    it "fails if used cores do not match allocated VMs" do
      vm_host = create_vm_host(total_cpus: 16, total_cores: 8, used_cores: 5)
      vm1 = create_vm(vm_host_id: vm_host.id, cores: 2, name: "test-vm-1")
      create_vm(vm_host_id: vm_host.id, cores: 0, name: "test-vm-2")
      create_vm_host_slice(vm_host_id: vm_host.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm1.id], "verify_host_capacity" => true})

      expect { vg_test.verify_host_capacity }.to hop("failed")
      expect(st.reload.exitval).to eq({"msg" => "Host used cores does not match the allocated VMs cores (vm_cores=2, slice_cores=1, used_cores=5)"})
    end
  end

  describe "#verify_vm_host_slices" do
    it "runs tests on vm host slices" do
      vm_host = create_vm_host
      slice1 = create_vm_host_slice(vm_host_id: vm_host.id, name: "slice1")
      slice2 = create_vm_host_slice(vm_host_id: vm_host.id, name: "slice2")
      vm1 = create_vm(vm_host_id: vm_host.id, vm_host_slice_id: slice1.id, name: "test-vm-1")
      vm2 = create_vm(vm_host_id: vm_host.id, vm_host_slice_id: slice2.id, name: "test-vm-2")
      vm3 = create_vm(vm_host_id: vm_host.id, name: "test-vm-3")
      refresh_frame(vg_test, new_values: {"test_slices" => true, "vms" => [vm1.id, vm2.id, vm3.id]})

      expect { vg_test.verify_vm_host_slices }.to hop("start", "Test::VmHostSlices")
    end

    it "hops to verify_firewall_rules if tests are done" do
      refresh_frame(vg_test, new_values: {"test_slices" => true})
      st.retval = {"msg" => "Verified VM Host Slices!"}
      expect { vg_test.verify_vm_host_slices }.to hop("verify_storage_rpc")
    end
  end

  describe "#verify_storage_rpc" do
    it "verifies vhost-block-backend version for each vm using RPC" do
      command = {command: "version"}.to_json
      expected_response = {version: Config.vhost_block_backend_version.delete_prefix("v")}.to_json + "\n"
      vm_host = create_vm_host
      vm1 = create_vm(vm_host_id: vm_host.id, name: "test-vm-1")
      vm2 = create_vm(vm_host_id: vm_host.id, name: "test-vm-2")
      refresh_frame(vg_test, new_values: {"vms" => [vm1.id, vm2.id]})

      expect(vg_test.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm1.inhost_name}/0/rpc.sock -q 0", stdin: command).and_return(expected_response)
      expect(vg_test.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm2.inhost_name}/0/rpc.sock -q 0", stdin: command).and_return(expected_response)

      expect { vg_test.verify_storage_rpc }.to hop("verify_firewall_rules")
    end

    it "fails if unable to get vhost-block-backend version using RPC" do
      command = {command: "version"}.to_json
      vm_host = create_vm_host
      vm1 = create_vm(vm_host_id: vm_host.id, name: "test-vm-1")
      refresh_frame(vg_test, new_values: {"vms" => [vm1.id]})

      expect(vg_test.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm1.inhost_name}/0/rpc.sock -q 0", stdin: command).and_return("{\"error\": \"some error\"}\n")

      expect { vg_test.verify_storage_rpc }.to hop("failed")
      expect(st.reload.exitval).to eq({"msg" => "Failed to get vhost-block-backend version for VM #{vm1.id} using RPC"})
    end
  end

  describe "#verify_firewall_rules" do
    it "hops to test_reboot if tests are done" do
      st.retval = {"msg" => "Verified Firewall Rules!"}
      expect { vg_test.verify_firewall_rules }.to hop("verify_connected_subnets")
    end

    it "runs tests for the first firewall" do
      refresh_frame(vg_test, new_values: {"subnets" => [ps1.id]})
      expect { vg_test.verify_firewall_rules }.to hop("start", "Test::FirewallRules")
    end
  end

  describe "#verify_connected_subnets" do
    it "hops to test_reboot if tests are done" do
      st.retval = {"msg" => "Verified Connected Subnets!"}
      expect { vg_test.verify_connected_subnets }.to hop("test_reboot")
    end

    it "runs tests for the first connected subnet" do
      refresh_frame(vg_test, new_values: {"subnets" => [ps1.id, ps2.id]})
      expect { vg_test.verify_connected_subnets }.to hop("start", "Test::ConnectedSubnets")
    end

    it "runs tests for the second connected subnet" do
      vm1 = create_vm(project_id: prj.id, name: "vm-1")
      vm2 = create_vm(project_id: prj.id, name: "vm-2")
      Nic.create(private_subnet_id: ps1.id, vm_id: vm1.id, name: "nic-1", private_ipv4: ps1.net4.nth(3).to_s, private_ipv6: ps1.net6.nth(3).to_s, mac: "00:00:00:00:00:01", state: "active")
      Nic.create(private_subnet_id: ps1.id, vm_id: vm2.id, name: "nic-2", private_ipv4: ps1.net4.nth(4).to_s, private_ipv6: ps1.net6.nth(4).to_s, mac: "00:00:00:00:00:02", state: "active")
      refresh_frame(vg_test, new_values: {"subnets" => [ps1.id, ps2.id]})
      expect { vg_test.verify_connected_subnets }.to hop("start", "Test::ConnectedSubnets")
    end

    it "hops to destroy_resources if tests are done and reboot is not set" do
      st.retval = {"msg" => "Verified Connected Subnets!"}
      refresh_frame(vg_test, new_values: {"test_reboot" => false})
      expect { vg_test.verify_connected_subnets }.to hop("destroy_resources")
    end
  end

  describe "#test_reboot" do
    it "hops to wait_reboot" do
      vm_host = create_vm_host
      vm = create_vm(vm_host_id: vm_host.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm.id]})
      expect { vg_test.test_reboot }.to hop("wait_reboot")
    end
  end

  describe "#wait_reboot" do
    let(:vm_host) { Prog::Vm::HostNexus.assemble("1.1.1.1").subject }

    before do
      vm = create_vm(vm_host_id: vm_host.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm.id]})
    end

    it "naps if strand is busy" do
      vm_host.strand.update(label: "reboot")
      expect { vg_test.wait_reboot }.to nap(20)
    end

    it "runs vm tests if reboot done" do
      vm_host.strand.update(label: "wait")
      expect { vg_test.wait_reboot }.to hop("verify_vms")
    end
  end

  describe "#destroy_resources" do
    it "hops to wait_resources_destroyed" do
      vm = create_vm(project_id: prj.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm.id], "subnets" => [ps1.id]})
      expect { vg_test.destroy_resources }.to hop("wait_resources_destroyed")
    end
  end

  describe "#wait_resources_destroyed" do
    it "hops to finish if all resources are destroyed" do
      vm = create_vm(project_id: prj.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm.id], "subnets" => [ps1.id]})
      vm.destroy
      ps1.destroy
      expect { vg_test.wait_resources_destroyed }.to hop("finish")
    end

    it "naps if all resources are not destroyed yet" do
      vm = create_vm(project_id: prj.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm.id], "subnets" => [ps1.id]})
      ps1.destroy
      expect { vg_test.wait_resources_destroyed }.to nap(5)
    end
  end

  describe "#finish" do
    it "exits" do
      refresh_frame(vg_test, new_values: {"project_id" => prj.id})
      expect { vg_test.finish }.to exit({"msg" => "VmGroup tests finished!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { vg_test.failed }.to nap(15)
    end
  end

  describe "#vm_host" do
    it "returns first VM's host" do
      vm_host = create_vm_host
      vm = create_vm(vm_host_id: vm_host.id)
      refresh_frame(vg_test, new_values: {"vms" => [vm.id]})
      expect(vg_test.vm_host).to eq(vm_host)
    end
  end
end
