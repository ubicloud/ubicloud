# frozen_string_literal: true

require_relative "../lib/slot"

RSpec.describe Slot do
  subject(:slot) { described_class.new(2, ip6_block: "2a01:4f8:120:9208:2::/79") }

  it "derives every per-slot name from the index" do
    expect(slot.name).to eq("emslot0002")
    expect(slot.netns).to eq("emslot0002")
    expect(slot.dir).to eq("/vm/emslot0002")
    expect(slot.uid).to eq(60_002)
    expect(slot.veth_host).to eq("emo2")
    expect(slot.veth_ns).to eq("emi2")
    expect(slot.link_host_ip6).to eq("fd00:b1c:ffff:2::1")
    expect(slot.link_ns_ip6).to eq("fd00:b1c:ffff:2::2")
  end

  it "offsets slot addresses past the network and gateway addresses" do
    expect(described_class.slot_address("2a01:4f8:120:9208:2::/79", 0)).to eq("2a01:4f8:120:9208:2::2")
    expect(slot.public_ip6).to eq("2a01:4f8:120:9208:2::4")
  end

  it "has no address when it was built without a block, for operations that do not need one" do
    expect(described_class.new(2).public_ip6).to be_nil
  end

  describe "#exists?" do
    it "is whether the namespace is there" do
      expect(File).to receive(:exist?).with("/var/run/netns/emslot0002").and_return(true)
      expect(slot).to exist
    end
  end

  describe "#create_user" do
    it "creates the slot user in the kvm group" do
      expect(slot).to receive(:user_exists?).and_return(false)
      expect(slot).to receive(:r).with("useradd", "--uid", slot.uid.to_s, "--no-create-home",
        "--home-dir", slot.dir, "--shell", "/usr/sbin/nologin", "--groups", "kvm", "emslot0002")
      slot.create_user
    end

    it "leaves an existing user alone, because setup is re-run" do
      expect(slot).to receive(:user_exists?).and_return(true)
      expect(slot).not_to receive(:r)
      slot.create_user
    end
  end

  describe "#user_exists?" do
    it "asks id" do
      expect(slot).to receive(:r).with("id", "-u", "emslot0002")
      expect(slot.user_exists?).to be true
    end

    it "is false when id says no" do
      expect(slot).to receive(:r).and_raise(CommandFail.new("no", "", ""))
      expect(slot.user_exists?).to be false
    end
  end

  describe "#create" do
    before do
      allow(slot).to receive_messages(create_user: nil, r: nil, ns: nil, apply_nftables: nil)
      allow(FileUtils).to receive_messages(mkdir_p: nil, chown_R: nil)
    end

    it "builds the namespace, the links and the tap, and hands the tap to the slot user" do
      expect(slot).to receive(:exists?).and_return(false)
      expect(slot).to receive(:ns).with("ip", "tuntap", "add", "dev", "cltap", "mode", "tap",
        "user", slot.uid.to_s)
      expect(FileUtils).to receive(:chown_R).with("emslot0002", "emslot0002", "/vm/emslot0002")
      slot.create
    end

    it "tears down what was there first, so setup can be re-run" do
      expect(slot).to receive(:exists?).and_return(true)
      expect(slot).to receive(:destroy_network)
      slot.create
    end
  end

  describe "#apply_nftables" do
    def ruleset_for(sources)
      written = nil
      expect(slot).to receive(:r)
        .with("ip", "netns", "exec", "emslot0002", "nft", "-f", "-", stdin: anything) { |*, stdin:|
          written = stdin
        }
      slot.apply_nftables(sources)
      written
    end

    it "admits only the given ingress sources, on whatever port the guest listens" do
      ruleset = ruleset_for(["2a01:4f8:10a:1:2::/80"])
      expect(ruleset).to include("elements = { 2a01:4f8:10a:1:2::/80 }")
      expect(ruleset).to include(%(ip6 daddr 2a01:4f8:120:9208:2::4 dnat ip6 to #{EmberConfig::GUEST_IP6}))
      expect(ruleset).to include(%(ip6 saddr @ingress_v6 ip6 daddr #{EmberConfig::GUEST_IP6} meta l4proto tcp ct state new accept))
      expect(ruleset).not_to include("dport")
      # Nothing leaves the guest.
      expect(ruleset).to include('iifname "cltap" drop')
      # And nothing may pretend to be the guest.
      expect(ruleset).to include("ether saddr != #{EmberConfig::GUEST_MAC} drop")
    end

    it "lets the host's end of the veth in, so the host can tell the guest is up" do
      ruleset = ruleset_for([])
      expect(ruleset).to include(%(iifname "emi2" oifname "cltap" ip6 saddr fd00:b1c:ffff:2::1 ip6 daddr #{EmberConfig::GUEST_IP6} meta l4proto tcp ct state new accept))
    end

    it "writes an empty set when no ingress source is known yet" do
      expect(ruleset_for([])).not_to include("elements =")
    end

    it "lets a failure from nft out, with its own diagnostics" do
      expect(slot).to receive(:r).and_raise(CommandFail.new("nft: syntax error", "", ""))
      expect { slot.apply_nftables([]) }.to raise_error(CommandFail, /syntax error/)
    end
  end

  describe "#destroy_network" do
    it "removes the namespace and the host-side link a create left behind" do
      expect(slot).to receive(:r).with("ip", "netns", "del", "emslot0002")
      expect(slot).to receive(:r).with("ip", "link", "del", "emo2")
      slot.destroy_network
    end

    it "does not mind the link having gone with the namespace" do
      expect(slot).to receive(:r).with("ip", "netns", "del", "emslot0002")
      expect(slot).to receive(:r).with("ip", "link", "del", "emo2").and_raise(CommandFail.new("no", "", ""))
      expect { slot.destroy_network }.not_to raise_error
    end
  end
end
