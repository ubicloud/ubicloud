# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::HostCleanup do
  subject(:nx) { described_class.new(described_class.assemble(vm_host.id)) }

  let(:vm_host) { create_vm_host(used_cores: 2, used_hugepages_1g: 16) }
  let(:sshable) { nx.sshable }

  describe "#expected_vm_names" do
    it "returns inhost names of all vms on the host" do
      vm1 = create_vm(vm_host_id: vm_host.id)
      vm2 = create_vm(vm_host_id: vm_host.id)
      expect(nx.expected_vm_names).to contain_exactly(vm1.inhost_name, vm2.inhost_name)
    end

    it "returns empty when no vms" do
      expect(nx.expected_vm_names).to eq([])
    end
  end

  describe "#expected_slice_names" do
    it "returns only our slice unit names" do
      create_vm_host_slice(vm_host_id: vm_host.id, name: "standard_vmabcdef")
      create_vm_host_slice(vm_host_id: vm_host.id, name: "burstable_vm123456")
      # Not vm-derived -> should be excluded.
      create_vm_host_slice(vm_host_id: vm_host.id, name: "standard")
      expect(nx.expected_slice_names).to contain_exactly("standard_vmabcdef.slice", "burstable_vm123456.slice")
    end
  end

  describe "#start" do
    it "hops to wait and does nothing unless host is accepting" do
      vm_host.update(allocation_state: "draining")
      expect { nx.start }.to hop("wait")
    end

    it "invokes cleanup-stale-vms with expected names and pops" do
      vm = create_vm(vm_host_id: vm_host.id, cores: 1)
      create_vm_host_slice(vm_host_id: vm_host.id, name: "standard_vmabcdef")

      captured = nil
      expect(sshable).to receive(:_cmd) { |cmd, **kw|
        captured = [cmd, kw]
        JSON.generate({"vms" => ["vm999999"], "slices" => []})
      }
      expect(Clog).to receive(:emit).with("VM host stale artifacts cleaned", hash_including(vm_host_stale_cleanup: hash_including(vms: ["vm999999"]))).and_call_original
      expect { nx.start }.to exit({"msg" => "stale vms cleaned"})
      expect(captured[0]).to eq("sudo host/bin/cleanup-stale-vms")
      expect(captured[1][:stdin]).to eq(JSON.generate({expected_vms: [vm.inhost_name], expected_slices: ["standard_vmabcdef.slice"]}))
      expect(captured[1][:log]).to eq(:on_error)
    end

    it "pops without logging when nothing stale" do
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/cleanup-stale-vms",
        stdin: JSON.generate({expected_vms: [], expected_slices: []}),
        log: :on_error,
      ).and_return(JSON.generate({"vms" => [], "slices" => []}))

      expect(Clog).not_to receive(:emit).with("VM host stale artifacts cleaned", anything)
      expect { nx.start }.to exit({"msg" => "stale vms cleaned"})
    end

    it "logs and naps when the host is unreachable" do
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/cleanup-stale-vms",
        stdin: JSON.generate({expected_vms: [], expected_slices: []}),
        log: :on_error,
      ).and_raise(Errno::ECONNREFUSED)
      expect(Clog).to receive(:emit).with("VM host stale artifact cleanup failed", hash_including(vm_host_stale_cleanup_failed: hash_including(exception: hash_including(class: "Errno::ECONNREFUSED")))).and_call_original
      expect { nx.start }.to nap(5 * 60)
    end
  end
end
