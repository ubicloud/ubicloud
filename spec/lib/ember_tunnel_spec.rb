# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe EmberTunnel do
  let(:host) {
    vm_host = create_ember_host(vm_host: create_vm_host(net6: "2a01:4f8:120:9208::/64", ip6: "2a01:4f8:120:9208::2"))
    PostgresGatewayHost.create_with_id(vm_host.id, postgres_gateway_id: gateway.id)
  }

  let(:gateway) {
    PostgresGateway.create(location_id: Location::HETZNER_FSN1_ID, hostname_suffix: "ember.test")
  }

  let(:gateway_vm_host) { create_vm_host(ip6: "2a01:4f8:10a:1::2") }

  let(:replica) {
    vm = create_vm(vm_host_id: gateway_vm_host.id, ephemeral_net6: "2a01:4f8:10a:1:2::/79")
    PostgresGatewayReplica.create(postgres_gateway_id: gateway.id, vm_id: vm.id, state: "running")
  }

  def keys_of(record) = JSON.parse(record.reload.tunnel_keys)

  describe ".new_key" do
    it "makes an AES-256-GCM key, with its salt, an SPI and a reqid clear of private subnets'" do
      key = described_class.new_key(outbound: true)
      expect(key["key"]).to match(/\A0x\h{72}\z/)
      expect(key["spi"]).to match(/\A0x\h{8}\z/)
      expect(described_class::REQID_RANGE).to cover(key["reqid"])
      expect(key["outbound"]).to be true
    end
  end

  describe ".ensure_keys" do
    it "gives an end one outbound key, once, and stores it encrypted" do
      described_class.ensure_keys(host)
      first = keys_of(host)
      expect(first["keys"].map { it["outbound"] }).to eq([true])
      expect(first["phase"]).to be_nil
      expect(host.tunnel_rekeyed_at).not_to be_nil
      expect(DB[:postgres_gateway_host].where(id: host.id).get(:tunnel_keys)).not_to include(first["keys"][0]["key"])

      described_class.ensure_keys(host)
      expect(keys_of(host)).to eq(first)
    end
  end

  describe ".endpoint" do
    it "ends a replica's tunnels in its VM's namespace, on the second half of its /79" do
      expect(described_class.endpoint(replica)).to eq({
        sshable: gateway_vm_host.sshable, netns: replica.vm.inhost_name,
        outer: "2a01:4f8:10a:1:3::", inner: "2a01:4f8:10a:1:2::/80",
      })
    end

    it "ends an ember host's in its own namespace, on its own address" do
      expect(described_class.endpoint(host)).to eq({
        sshable: host.vm_host.sshable, netns: nil,
        outer: "2a01:4f8:120:9208::2", inner: "2a01:4f8:120:9208:2::/79",
      })
    end
  end

  describe ".peers" do
    it "pairs replicas with the location's ember hosts that have keys, and the other way round" do
      described_class.ensure_keys(host)
      described_class.ensure_keys(replica)
      create_ember_host
      expect(described_class.peers(replica).map(&:id)).to eq([host.id])
      expect(described_class.peers(host).map(&:id)).to eq([replica.id])
    end

    it "has no peers for a host in a location with no gateway" do
      expect(described_class.peers(host)).to eq([])
    end
  end

  describe ".spec" do
    before do
      described_class.ensure_keys(host)
      described_class.ensure_keys(replica)
    end

    it "is this end's outbound key and every key each peer may send with" do
      spec = described_class.spec(replica)
      expect(spec["netns"]).to eq(replica.vm.inhost_name)
      expect(spec["self"]).to include("outer" => "2a01:4f8:10a:1:3::", "inner" => "2a01:4f8:10a:1:2::/80")
      expect(spec["self"]["outbound"]).to eq(keys_of(replica)["keys"][0].slice("spi", "reqid", "key"))
      expect(spec["peers"]).to eq([{"outer" => "2a01:4f8:120:9208::2", "inner" => "2a01:4f8:120:9208:2::/79",
                                    "keys" => [keys_of(host)["keys"][0].slice("spi", "reqid", "key")]}])
    end

    it "takes its serial before it reads the database, so a later view carries a later serial" do
      first = described_class.spec(host)["serial"]
      expect(described_class.spec(host)["serial"]).to be > first
    end
  end

  describe ".push" do
    it "hands the spec to the host on stdin and records when" do
      described_class.ensure_keys(host)
      expect(host.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/setup-ember-tunnel", stdin: anything) { |_, stdin:|
        expect(JSON.parse(stdin)["netns"]).to be_nil
      }
      described_class.push(host)
      expect(host.reload.tunnel_pushed_at).not_to be_nil
    end
  end

  describe ".reapply_due?" do
    it "is never due for an end with no keys yet" do
      expect(described_class.reapply_due?(host)).to be false
    end

    it "is due when never pushed, or not for a while, and not otherwise" do
      described_class.ensure_keys(host)
      expect(described_class.reapply_due?(host)).to be true
      host.update(tunnel_pushed_at: Time.now - described_class::REAPPLY_INTERVAL - 1)
      expect(described_class.reapply_due?(host)).to be true
      host.update(tunnel_pushed_at: Time.now)
      expect(described_class.reapply_due?(host)).to be false
    end
  end

  describe ".push_peers" do
    before do
      described_class.ensure_keys(host)
      described_class.ensure_keys(replica)
    end

    it "skips a peer that is down" do
      replica.update(state: "draining")
      expect(described_class).not_to receive(:push)
      described_class.push_peers(host)
    end

    it "tries every peer that is up, and says which it could not reach" do
      second_host = create_ember_host(vm_host: create_vm_host(ip6: "2a01:4f8:120:9209::2"))
      second = PostgresGatewayHost.create_with_id(second_host.id, postgres_gateway_id: gateway.id)
      described_class.ensure_keys(second)
      expect(described_class).to receive(:push).with(having_attributes(id: host.id)).and_raise("ssh refused")
      expect(described_class).to receive(:push).with(having_attributes(id: second.id))
      expect { described_class.push_peers(replica) }
        .to raise_error(EmberTunnel::PushFailed, /#{host.ubid}/)
    end

    it "counts an ember host as up until the monitor gives up on it" do
      strand = Strand.create_with_id(host.vm_host, prog: "Vm::HostNexus", label: "wait")
      expect(described_class.live?(host)).to be true
      strand.update(label: "unavailable")
      expect(described_class.live?(host.reload)).to be false
    end
  end

  describe ".rekey_due?" do
    it "is never due for an end with no keys yet" do
      expect(described_class.rekey_due?(host)).to be false
    end

    it "is due once a day, when never rotated, and while a rotation is under way" do
      described_class.ensure_keys(host)
      expect(described_class.rekey_due?(host)).to be false
      host.update(tunnel_rekeyed_at: Time.now - described_class::REKEY_INTERVAL - 1)
      expect(described_class.rekey_due?(host)).to be true
      host.update(tunnel_rekeyed_at: nil)
      expect(described_class.rekey_due?(host)).to be true
      host.update(tunnel_rekeyed_at: Time.now)
      described_class.save_keys(host, keys_of(host).merge("phase" => "switching"))
      expect(described_class.rekey_due?(host)).to be true
    end
  end

  describe ".rekey" do
    before { described_class.ensure_keys(host) }

    it "has the peers accept the new key, sends with it, then has them forget the old one" do
      old = keys_of(host)["keys"][0]
      seen = []
      expect(described_class).to receive(:push_peers).with(host).twice { seen << [:peers, keys_of(host)] }
      expect(described_class).to receive(:push).with(host) { seen << [:self, keys_of(host)] }
      described_class.rekey(host)

      # Peers first learn both keys, with the old one still the one in use...
      phase, keys = seen[0]
      expect(phase).to eq(:peers)
      expect(keys["keys"].map { it["outbound"] }).to eq([true, false])
      # ...then this end switches to the new one...
      phase, keys = seen[1]
      expect(phase).to eq(:self)
      expect(keys["keys"].map { it["outbound"] }).to eq([false, true])
      # ...and only then do the peers drop the old one.
      phase, keys = seen[2]
      expect(phase).to eq(:peers)
      expect(keys["keys"].size).to eq(1)

      final = keys_of(host)
      expect(final["phase"]).to be_nil
      expect(final["keys"].size).to eq(1)
      expect(final["keys"][0]["spi"]).not_to eq(old["spi"])
      expect(host.tunnel_rekeyed_at).to be_within(5).of(Time.now)
    end

    it "stays where it stopped when a peer cannot be reached, and picks up there" do
      expect(described_class).to receive(:push_peers).and_raise(EmberTunnel::PushFailed, "down")
      expect { described_class.rekey(host) }.to raise_error(EmberTunnel::PushFailed)
      expect(keys_of(host)["phase"]).to eq("adding")
      expect(keys_of(host)["keys"].size).to eq(2)

      allow(described_class).to receive(:push_peers)
      allow(described_class).to receive(:push)
      described_class.rekey(host)
      expect(keys_of(host)["phase"]).to be_nil
      expect(keys_of(host)["keys"].size).to eq(1)
    end
  end
end
