# frozen_string_literal: true

RSpec.describe Prog::Vnet::RekeyNic do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    PrivateSubnet.create_with_id(name: "ps", location: "hetzner-hel1", net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting")
  }
  let(:tunnel) {
    n_src = Nic.create_with_id(private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
      private_ipv4: "10.0.0.1",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic")
    n_dst = Nic.create_with_id(private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:def::",
      private_ipv4: "10.0.0.2",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic")
    IpsecTunnel.create_with_id(src_nic_id: n_src.id, dst_nic_id: n_dst.id).tap { _1.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
  }

  before do
    nx.instance_variable_set(:@nic, tunnel.src_nic)
  end

  describe ".sshable_cmd" do
    let(:sshable) { instance_double(Sshable) }
    let(:vm) {
      vmh = instance_double(VmHost, sshable: sshable)
      instance_double(Vm, vm_host: vmh)
    }

    it "returns vm_host sshable of source nic" do
      expect(nx.nic).to receive(:vm).and_return(vm)
      expect(sshable).to receive(:cmd).with("echo hello")
      nx.sshable_cmd("echo hello")
    end
  end

  describe "#start" do
    let(:vm) {
      instance_double(Vm, name: "hellovm", id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e",
        ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"))
    }

    before do
      expect(nx).to receive(:frame).and_return(
        {
          "payload" => {tunnel.src_nic.id =>
            {reqid: 86879, spi4: "0xe3af3a04", spi6: "0xe3af3a04"}},
          :subject_id => tunnel.src_nic.id
        }
      )
      expect(tunnel).to receive(:vm_name).with(tunnel.src_nic).and_return("hellovm")
      expect(tunnel.src_nic).to receive(:vm).and_return(vm)
      expect(tunnel.dst_nic).to receive(:vm).and_return(vm)
      expect(tunnel.src_nic).to receive(:dst_ipsec_tunnels).and_return([tunnel])
    end

    it "hops to wait_outbound_trigger" do
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi  reqid  mode tunnel aead 'rfc4106(gcm(aes))' 0x736f6d655f656e6372797074696f6e5f6b6579 128 sel src 0.0.0.0/0 dst 0.0.0.0/0 ").and_return(true)
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi  reqid  mode tunnel aead 'rfc4106(gcm(aes))' 0x736f6d655f656e6372797074696f6e5f6b6579 128").and_return(true)
      expect {
        nx.start
      }.to hop("wait_outbound_trigger")
    end
  end

  describe "#wait_outbound_trigger" do
    it "waits if semaphore is not set" do
      sem = instance_double(SemSnap)
      expect(sem).to receive(:set?).with("trigger_outbound_update").and_return(false)
      expect(SemSnap).to receive(:new).with(nx.nic.id).and_return(sem)
      expect {
        nx.wait_outbound_trigger
      }.to nap(1)
    end

    it "hops to replace_policies if semaphore is set" do
      sem = instance_double(SemSnap)
      expect(sem).to receive(:set?).with("trigger_outbound_update").and_return(true)
      expect(SemSnap).to receive(:new).with(nx.nic.id).and_return(sem).twice
      expect(sem).to receive(:decr).with("trigger_outbound_update").and_return(true)
      expect {
        nx.wait_outbound_trigger
      }.to hop("setup_outbound")
    end
  end

  describe "#replace_policies" do
    let(:vm) {
      instance_double(Vm, name: "hellovm", id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e",
        ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"), inhost_name: "inhost")
    }

    before do
      expect(nx).to receive(:frame).and_return(
        {
          "payload" => {tunnel.src_nic.id =>
            {reqid: 86879, spi4: "0xe3af3a04", spi6: "0xe3af3a04"}},
          :subject_id => tunnel.src_nic.id
        }
      ).at_least(:once)
      expect(tunnel).to receive(:vm_name).with(tunnel.src_nic).and_return("hellovm").at_least(:once)
      expect(tunnel.src_nic).to receive(:vm).and_return(vm).at_least(:once)
      expect(tunnel.dst_nic).to receive(:vm).and_return(vm).at_least(:once)
      expect(tunnel.src_nic).to receive(:src_ipsec_tunnels).and_return([tunnel]).at_least(:once)
    end

    it "creates new state and policy for src" do
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi  reqid  mode tunnel aead 'rfc4106(gcm(aes))' 0x736f6d655f656e6372797074696f6e5f6b6579 128 sel src 0.0.0.0/0 dst 0.0.0.0/0 ").and_return(true)
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi  reqid  mode tunnel aead 'rfc4106(gcm(aes))' 0x736f6d655f656e6372797074696f6e5f6b6579 128").and_return(true)
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n hellovm xfrm policy update src 10.0.0.1/32 dst 10.0.0.2/32 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid  mode tunnel").and_return(true)
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n hellovm xfrm policy update src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid  mode tunnel").and_return(true)
      expect {
        nx.setup_outbound
      }.to hop("wait_state_drop_trigger")
    end
  end

  describe "#wait_state_drop_trigger" do
    it "waits if semaphore is not set" do
      sem = instance_double(SemSnap)
      expect(sem).to receive(:set?).with("old_state_drop").and_return(false)
      expect(SemSnap).to receive(:new).with(nx.nic.id).and_return(sem)
      expect {
        nx.wait_state_drop_trigger
      }.to nap(1)
    end

    it "hops to old_state_drop if semaphore is set" do
      sem = instance_double(SemSnap)
      expect(sem).to receive(:set?).with("old_state_drop").and_return(true)
      expect(SemSnap).to receive(:new).with(nx.nic.id).and_return(sem).twice
      expect(sem).to receive(:decr).with("old_state_drop").and_return(true)
      expect {
        nx.wait_state_drop_trigger
      }.to hop("old_state_drop")
    end
  end

  describe "#old_state_drop" do
    let(:vm) {
      instance_double(Vm, name: "hellovm", id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e",
        ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"), inhost_name: "inhost")
    }
    let(:states_data) {
      "src 2a01:4f8:10a:128b:7537:: dst 2a01:4f8:10a:128b:4919::
proto esp spi 0xe1111111 reqid 49966 mode tunnel
replay-window 0
aead rfc4106(gcm(aes)) 0x6c838df72ba3abe1a2643ee104e21d617830f1b765addced5e26d17a4cc5048d1468ac54 128
anti-replay context: seq 0x0, oseq 0x0, bitmap 0x00000000
sel src ::/0 dst ::/0
src 2a01:4f8:10a:128b:7537:: dst 2a01:4f8:10a:128b:4919::
proto esp spi 0x22222222 reqid 49966 mode tunnel
replay-window 0
aead rfc4106(gcm(aes)) 0x6c838df72ba3abe1a2643ee104e21d617830f1b765addced5e26d17a4cc5048d1468ac54 128
anti-replay context: seq 0x0, oseq 0x0, bitmap 0x00000000
sel src 0.0.0.0/0 dst 0.0.0.0/0
src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537::
proto esp spi 0x610a9eb5 reqid 29850 mode tunnel
replay-window 0
aead rfc4106(gcm(aes)) 0xc0c6485e1020fd7178cf9bed74b91cfee06bc5b19066db12ec0d801737954296f1894134 128
anti-replay context: seq 0x0, oseq 0x0, bitmap 0x00000000
sel src ::/0 dst ::/0
src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537::
proto esp spi 0x059e11e6 reqid 29850 mode tunnel
replay-window 0
aead rfc4106(gcm(aes)) 0xc0c6485e1020fd7178cf9bed74b91cfee06bc5b19066db12ec0d801737954296f1894134 128
anti-replay context: seq 0x0, oseq 0x0, bitmap 0x00000000
sel src 0.0.0.0/0 dst 0.0.0.0/0"
    }

    before do
      expect(nx).to receive(:frame).and_return(
        {
          "payload" =>
          {
            tunnel.src_nic.id => {"reqid" => 86879, "spi4" => "0x22222222", "spi6" => "0x33333333"},
            tunnel.dst_nic.id => {"reqid" => 14329, "spi4" => "0xe0000000", "spi6" => "0xe1111111"}
          },
          :subject_id => tunnel.src_nic.id
        }
      ).at_least(:once)
      #      expect(tunnel).to receive(:vm_name).with(tunnel.src_nic).and_return("hellovm").at_least(:once)
      expect(tunnel.src_nic).to receive(:vm).and_return(vm).at_least(:once)
      # expect(tunnel.dst_nic).to receive(:vm).and_return(vm).at_least(:once)
      # expect(tunnel.src_nic).to receive(:src_ipsec_tunnels).and_return([tunnel]).at_least(:once)
    end

    it "drops old states and pops" do
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n inhost xfrm state").and_return(states_data)
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n inhost xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x610a9eb5").and_return(true)
      expect(nx).to receive(:sshable_cmd).with("sudo ip -n inhost xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x059e11e6").and_return(true)
      expect(nx).to receive(:pop).with("wait_state_drop").and_return(true)
      nx.old_state_drop
    end
  end
end
