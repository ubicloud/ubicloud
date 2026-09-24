# frozen_string_literal: true

require_relative "../lib/ember_tunnel_xfrm"
require "tmpdir"

RSpec.describe EmberTunnelXfrm do
  subject(:xfrm) { described_class.new(spec) }

  let(:serial) { 100 }
  let(:netns) { "vmgateway" }
  let(:spec) {
    {
      "serial" => serial,
      "netns" => netns,
      "self" => {"outer" => "2a01:4f8::8000", "inner" => "2a01:4f8::/65",
                 "outbound" => {"spi" => "0x0000000a", "reqid" => 100_001, "key" => "0xaa"}},
      "peers" => [{"outer" => "2a01:4f9::2", "inner" => "2a01:4f9:0:0:2::/79",
                   "keys" => [{"spi" => "0x0000000b", "reqid" => 100_002, "key" => "0xbb"}]}],
    }
  }

  around do |example|
    Dir.mktmpdir do |dir|
      @state_dir = dir
      example.run
    end
  end

  before { stub_const("EmberTunnelXfrm::STATE_DIR", @state_dir) }

  def kernel(*states)
    states.map { |src, dst, spi| "src #{src} dst #{dst}\n\tproto esp spi #{spi} reqid 1 mode tunnel\n" }.join
  end

  def expect_policy_updates(prefix = ["-n", netns])
    expect(xfrm).to receive(:r).with("ip", *prefix, "xfrm", "policy", "update", "src", "2a01:4f8::/65",
      "dst", "2a01:4f9:0:0:2::/79", "dir", "out", "tmpl", "src", "2a01:4f8::8000", "dst", "2a01:4f9::2",
      "proto", "esp", "reqid", "100001", "mode", "tunnel", stdin: nil)
    expect(xfrm).to receive(:r).with("ip", *prefix, "xfrm", "policy", "update", "src", "2a01:4f9:0:0:2::/79",
      "dst", "2a01:4f8::/65", "dir", "fwd", "tmpl", "src", "2a01:4f9::2", "dst", "2a01:4f8::8000",
      "proto", "esp", "reqid", "0", "mode", "tunnel", stdin: nil)
  end

  it "wants an outbound state per peer and an inbound one per key a peer may send with" do
    expect(xfrm.desired_states).to eq([
      ["2a01:4f8::8000", "2a01:4f9::2", "0x0000000a", 100_001, "0xaa"],
      ["2a01:4f9::2", "2a01:4f8::8000", "0x0000000b", 100_002, "0xbb"],
    ])
  end

  it "wants an out policy towards each peer and a fwd policy for what comes back" do
    expect(xfrm.desired_policies.map { |policy| policy.first(3) }).to eq([
      ["2a01:4f8::/65", "2a01:4f9:0:0:2::/79", "out"],
      ["2a01:4f9:0:0:2::/79", "2a01:4f8::/65", "fwd"],
    ])
  end

  describe "#apply" do
    it "adds what is missing, with the keys on stdin rather than in a command line" do
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "xfrm", "state", stdin: nil).and_return("")
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "-batch", "-", stdin: anything) { |*, stdin:|
        expect(stdin.lines).to eq([
          "xfrm state add src 2a01:4f8::8000 dst 2a01:4f9::2 proto esp spi 0x0000000a reqid 100001 mode tunnel " \
          "aead rfc4106(gcm(aes)) 0xaa 128 flag esn replay-window 4096\n",
          "xfrm state add src 2a01:4f9::2 dst 2a01:4f8::8000 proto esp spi 0x0000000b reqid 100002 mode tunnel " \
          "aead rfc4106(gcm(aes)) 0xbb 128 flag esn replay-window 4096\n",
        ])
      }
      expect_policy_updates
      expect(xfrm.apply).to be true

      state = JSON.parse(File.read(xfrm.state_file))
      expect(state["serial"]).to eq(100)
      # The keys stay out of the state file; it only records what is ours.
      expect(File.read(xfrm.state_file)).not_to include("0xaa")
      expect(state["policies"]).to include(["2a01:4f8::/65", "2a01:4f9:0:0:2::/79", "out"])
      expect(File.stat(xfrm.state_file).mode & 0o777).to eq(0o600)
    end

    it "adds nothing that is already there, and so is idempotent" do
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "xfrm", "state", stdin: nil).and_return(kernel(
        ["2a01:4f8::8000", "2a01:4f9::2", "0x0000000a"], ["2a01:4f9::2", "2a01:4f8::8000", "0x0000000b"],
      ))
      expect(xfrm).not_to receive(:r).with("ip", "-n", netns, "-batch", "-", stdin: anything)
      expect_policy_updates
      xfrm.apply
    end

    it "removes what it installed and no longer wants, after putting the new states in place" do
      File.write(xfrm.state_file, JSON.generate({
        "serial" => 50,
        # What it installed last time: some of it still wanted, some not.
        "states" => [["2a01:4f8::8000", "2a01:4f9::2", "0x00000001"], ["2a01:4f8::8000", "2a01:4f9::9", "0x00000001"],
          ["2a01:4f9::2", "2a01:4f8::8000", "0x0000000b"]],
        "policies" => [["2a01:4f8::/65", "2a01:4f9:0:0:9::/79", "out"], ["2a01:4f8::/65", "2a01:4f9:0:0:8::/79", "out"],
          ["2a01:4f8::/65", "2a01:4f9:0:0:2::/79", "out"]],
      }))
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "xfrm", "state", stdin: nil).and_return(kernel(
        ["2a01:4f8::8000", "2a01:4f9::2", "0x00000001"],
        ["2a01:4f9::2", "2a01:4f8::8000", "0x0000000b"],
        # A private subnet's state in the same namespace, which is not ours.
        ["2a01:4f8::8000", "2a01:4f7::8000", "0x00000077"],
      )).ordered
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "-batch", "-", stdin: anything).ordered
      expect_policy_updates
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "xfrm", "policy", "delete", "src", "2a01:4f8::/65",
        "dst", "2a01:4f9:0:0:9::/79", "dir", "out", stdin: nil).ordered
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "xfrm", "policy", "delete", "src", "2a01:4f8::/65",
        "dst", "2a01:4f9:0:0:8::/79", "dir", "out", stdin: nil).and_raise(CommandFail.new("no such policy", "", "")).ordered
      # The old outbound key goes; the state for a peer that has left was
      # already gone from the kernel, so nothing is asked of it.
      expect(xfrm).to receive(:r).with("ip", "-n", netns, "xfrm", "state", "delete", "src", "2a01:4f8::8000",
        "dst", "2a01:4f9::2", "proto", "esp", "spi", "0x00000001", stdin: nil).ordered
      expect(xfrm.apply).to be true
    end

    it "refuses a spec older than the last one it applied" do
      File.write(xfrm.state_file, JSON.generate({"serial" => 200}))
      expect(xfrm).not_to receive(:r)
      expect(xfrm.apply).to be false
    end

    it "starts over from a state file it cannot read" do
      File.write(xfrm.state_file, "not json")
      allow(xfrm).to receive(:r).and_return("")
      expect(xfrm.apply).to be true
    end

    context "when on an ember host, where the tunnel ends in the root namespace" do
      let(:netns) { nil }

      it "runs ip without a namespace, keeps its state under root, and only lets IPsec traffic into slots" do
        expect(xfrm.state_file).to end_with("/root.json")
        expect(xfrm).to receive(:r).with("ip", "xfrm", "state", stdin: nil).and_return(kernel(
          ["2a01:4f8::8000", "2a01:4f9::2", "0x0000000a"], ["2a01:4f9::2", "2a01:4f8::8000", "0x0000000b"],
        ))
        expect_policy_updates([])
        expect(xfrm).to receive(:r).with("nft", "-f", "-", stdin: /oifname "emo\*" meta ipsec missing counter drop/)
        xfrm.apply
      end
    end
  end
end
