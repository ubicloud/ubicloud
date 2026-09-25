# frozen_string_literal: true

require_relative "../lib/ip_reachability_check"

RSpec.describe IpReachabilityCheck do
  subject(:check) { described_class.new(ips) }

  let(:ips) { ["10.0.0.1", "10.0.0.2"] }
  let(:ip_addr_show) {
    [
      {"ifname" => "lo", "addr_info" => [{"local" => "127.0.0.1"}, {"local" => "10.0.0.2"}]},
      {"ifname" => "eth0", "addr_info" => [{"local" => "10.0.0.9"}]},
      {"ifname" => "eth1"},
    ].to_json
  }
  let(:replies) { Hash.new(5) }
  let(:commands) { [] }

  def ping(received)
    "5 packets transmitted, #{received} received, #{100 - received * 20}% packet loss, time 800ms\n"
  end

  before do
    mutex = Mutex.new
    allow(check).to receive(:_run_command) do |*command, **kw|
      mutex.synchronize { commands << command }
      case command
      in ["ping", *, "-I", source, target]
        expect(kw).to eq(expect: [0, 1])
        raise CommandFail.new("bind failed", "", "") if replies[[source, target]] == :error
        ping(replies[[source, target]])
      in ["ping", *, target]
        ping(replies[[nil, target]])
      in ["ip", "-j", "-4", "addr", "show"]
        ip_addr_show
      in ["ip", "addr", "replace" | "del", _, "dev", "lo"]
        ""
      end
    end
  end

  it "binds each address it checks to lo for the duration" do
    expect(check.run).to eq []

    expect(commands).to include(
      ["ip", "addr", "replace", "10.0.0.1/32", "dev", "lo"],
      ["ping", "-n", "-q", "-c", "5", "-i", "0.2", "-W", "2", "-I", "10.0.0.1", "1.1.1.1"],
      ["ping", "-n", "-q", "-c", "5", "-i", "0.2", "-W", "2", "-I", "10.0.0.1", "8.8.8.8"],
      ["ip", "addr", "del", "10.0.0.1/32", "dev", "lo"],
    )
    # An address a previous run left on lo is still cleaned up.
    expect(commands).to include(["ip", "addr", "del", "10.0.0.2/32", "dev", "lo"])
  end

  context "with an address the host configured" do
    let(:ips) { ["10.0.0.9"] }

    it "uses it as it is" do
      expect(check.run).to eq []
      expect(commands.map(&:first).uniq).to eq ["ping", "ip"]
    end
  end

  it "reports addresses missing any target the host reaches" do
    replies[["10.0.0.2", "8.8.8.8"]] = 0

    expect(check.run).to eq ["10.0.0.2"]
  end

  it "ignores targets the host itself cannot reach" do
    replies[[nil, "8.8.8.8"]] = 0
    replies[["10.0.0.1", "8.8.8.8"]] = 0

    expect(check.run).to eq []
  end

  it "fails when the host reaches no target" do
    replies[[nil, "1.1.1.1"]] = 0
    replies[[nil, "8.8.8.8"]] = 0
    replies[[nil, "9.9.9.9"]] = 0

    expect { check.run }.to raise_error RuntimeError, "host cannot reach any of 1.1.1.1, 8.8.8.8, 9.9.9.9"
  end

  it "doesn't report an address that recovers on the second check" do
    calls = 0
    allow(check).to receive(:reachable?).and_call_original
    allow(check).to receive(:reachable?).with("10.0.0.1", "1.1.1.1") { (calls += 1) > 1 }

    expect(check.run).to eq []
    expect(calls).to eq 2
  end

  it "removes the address even if the check raises" do
    replies[["10.0.0.1", "1.1.1.1"]] = :error

    expect { check.run }.to raise_error CommandFail
    expect(commands).to include(["ip", "addr", "del", "10.0.0.1/32", "dev", "lo"])
  end

  context "without addresses" do
    let(:ips) { [] }

    it "checks nothing" do
      expect(check.run).to eq []
      expect(commands.map(&:first).uniq).to eq ["ping"]
    end
  end
end
