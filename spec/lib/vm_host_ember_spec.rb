# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe VmHostEmber do
  let(:host) { create_ember_host(vm_host: create_vm_host(net6: "fd00:1::/64", ip6: "fd00:1:2::2")) }
  let(:ember) { host.ember }

  it "is there only on a host brought up to run embers" do
    expect(ember.vm_host).to eq(host)
    expect(create_vm_host.ember).to be_nil
  end

  describe "#ip6_block" do
    it "takes the first /79 of the host's network when the host's address is elsewhere" do
      expect(ember.ip6_block.to_s).to eq("fd00:1::/79")
    end

    it "takes the next one when the first holds the host's address" do
      host.update(ip6: "fd00:1::2")
      expect(ember.ip6_block.to_s).to eq("fd00:1::2:0:0:0/79")
    end
  end

  describe "#max_slots" do
    it "divides the host's memory, less its own share, into slots" do
      expect(ember.max_slots).to eq(56 * 1024 / (Config.ember_default_memory_mib + 32))
    end
  end

  describe "#slot_ip6" do
    it "gives each slot a stable address from the host's block" do
      expect(ember.slot_ip6(0)).to eq("fd00:1::2")
      expect(ember.slot_ip6(1)).to eq("fd00:1::3")
    end

    it "refuses slots outside the host's range" do
      expect { ember.slot_ip6(-1) }.to raise_error(ArgumentError, /out of range/)
      expect { ember.slot_ip6(ember.max_slots) }.to raise_error(ArgumentError, /out of range/)
    end
  end

  describe "slot accounting" do
    it "counts the pool's volumes waiting here as blanks" do
      add_ember_blanks(host, 2)
      create_detachable_volume(vm_host_id: host.id, owner_id: create_ember.id)
      expect(ember.blank_slots).to eq(2)
    end

    it "leaves free what neither an ember nor a blank holds" do
      add_ember_blanks(host, 2)
      create_ember(vm_host_id: host.id, state: "running")
      create_ember(state: "paused")
      expect(ember.free_slots).to eq(ember.max_slots - 3)
    end
  end

  describe "#ubiblk_version" do
    it "picks the newest ubiblk on the host that is new enough" do
      VhostBlockBackend.create(vm_host_id: host.id, version: "v0.5.99", allocation_weight: 0)
      VhostBlockBackend.create(vm_host_id: host.id, version: "v0.4.2", allocation_weight: 100)
      expect(ember.ubiblk_version).to eq("v0.5.99")
    end

    it "refuses a host with nothing new enough" do
      host.vhost_block_backends_dataset.update(version_code: 402)
      expect { ember.ubiblk_version }.to raise_error(RuntimeError, /no ubiblk new enough/)
    end
  end

  describe "#available?" do
    it "is available until the monitor gives up on the host" do
      Strand.create_with_id(host, prog: "Vm::HostNexus", label: "wait")
      expect(ember).to be_available
      host.incr_checkup
      expect(ember).not_to be_available
    end

    it "is not available while the host is unavailable" do
      Strand.create_with_id(host, prog: "Vm::HostNexus", label: "unavailable")
      expect(ember).not_to be_available
    end
  end

  describe "#cmd_json" do
    it "sends what the host needs to know about itself along with the payload" do
      expect(host.sshable).to receive(:_cmd).with("sudo host/bin/ember describe e1", stdin: {
        "host" => {"max_slots" => ember.max_slots, "ip6_block" => "fd00:1::/79", "ch_version" => Config.ember_ch_version,
                   "ubiblk_version" => "v0.5.1"},
        "generation" => 3,
      }.to_json).and_return("{}")
      expect(ember.cmd_json("sudo host/bin/ember describe :ember", ember: "e1", stdin: {"generation" => 3})).to eq({})
    end
  end
end
