# frozen_string_literal: true

require_relative "spec_helper"

# What a VmHost answers about the embers it carries.
RSpec.describe VmHost do
  describe ".ember_candidates_for" do
    let(:template) { create_ember_template(workload: "fake") }

    before { stub_ember_workload }

    def ready_host(blanks: 0, **args)
      h = create_ember_host(**args)
      add_ember_blanks(h, blanks)
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: h.id, state: "ready")
      h
    end

    it "prefers a host with a blank waiting over one with more free slots" do
      with_blank = ready_host(blanks: 1, total_mem_gib: 16)
      with_slots = ready_host(total_mem_gib: 64)
      expect(described_class.ember_candidates_for(template).map(&:id)).to eq([with_blank.id, with_slots.id])
    end

    it "falls back to free slots when no host has a blank" do
      fewer = ready_host(total_mem_gib: 16)
      more = ready_host(total_mem_gib: 64)
      expect(described_class.ember_candidates_for(template).map(&:id)).to eq([more.id, fewer.id])
    end

    it "excludes hosts that have not built the template" do
      create_ember_host
      expect(described_class.ember_candidates_for(template)).to be_empty
    end

    it "excludes hosts still building the template" do
      h = create_ember_host
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: h.id, state: "building")
      expect(described_class.ember_candidates_for(template)).to be_empty
    end

    it "excludes hosts that are not brought up for embers" do
      ready_host(accepts_embers: false)
      expect(described_class.ember_candidates_for(template)).to be_empty
    end

    it "excludes hosts that are drained" do
      ready_host(allocation_state: "draining")
      expect(described_class.ember_candidates_for(template)).to be_empty
    end

    it "excludes hosts the monitor has given up on" do
      Strand.create_with_id(ready_host, prog: "Vm::HostNexus", label: "unavailable")
      checked = ready_host
      Strand.create_with_id(checked, prog: "Vm::HostNexus", label: "wait")
      checked.incr_checkup
      expect(described_class.ember_candidates_for(template)).to be_empty
    end

    it "excludes hosts whose CPU cannot restore the template" do
      ready_host(cpu_signature: "GenuineIntel-6-143-8/53.0")
      expect(described_class.ember_candidates_for(template)).to be_empty
    end

    it "excludes hosts in another location" do
      ready_host(vm_host: create_vm_host(location_id: Location::HETZNER_HEL1_ID))
      expect(described_class.ember_candidates_for(template)).to be_empty
    end
  end
end
