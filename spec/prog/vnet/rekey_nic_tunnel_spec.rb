# frozen_string_literal: true

RSpec.describe Prog::Vnet::RekeyNicTunnel do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: Project.create(name: "test").id)
  }
  let(:tunnel) {
    vmh = create_vm_host
    vm_src = create_vm(name: "hellovm", vm_host_id: vmh.id)
    vm_dst = create_vm(name: "hellovm2", vm_host_id: vmh.id)
    n_src = Nic.create(private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
      private_ipv4: "10.0.0.1",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic",
      rekey_payload: {"reqid" => 86879, "spi4" => "0xe2222222", "spi6" => "0xe3333333"},
      vm_id: vm_src.id, state: "active")
    n_dst = Nic.create(private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:def::",
      private_ipv4: "10.0.0.2",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic",
      rekey_payload: {"reqid" => 14329, "spi4" => "0xe0000000", "spi6" => "0xe1111111"},
      vm_id: vm_dst.id, state: "active")
    IpsecTunnel.create(src_nic_id: n_src.id, dst_nic_id: n_dst.id).tap { it.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
  }

  before do
    nx.instance_variable_set(:@nic, tunnel.src_nic)
  end

  describe "#before_run" do
    let(:vm_host) { tunnel.src_nic.vm.vm_host }

    it "pops when destroy is set" do
      Strand.create_with_id(tunnel.src_nic, prog: "Vnet:NicNexus", label: "wait_vm")
      tunnel.src_nic.incr_destroy
      expect { nx.before_run }.to exit({"msg" => "nic.destroy semaphore is set"})
    end

    it "pops when vm is nil" do
      tunnel.src_nic.update(vm_id: nil)
      expect { nx.before_run }.to exit({"msg" => "nic cannot take part in rekey"})
    end

    it "pops when vm is deleting" do
      tunnel.src_nic.vm.update(display_state: "deleting")
      expect { nx.before_run }.to exit({"msg" => "nic cannot take part in rekey"})
    end

    it "pops when the host is down and unreachable" do
      Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "unavailable")
      expect(vm_host.sshable).to receive(:_cmd).with("true").and_raise(Errno::ECONNREFUSED)
      expect { nx.before_run }.to exit({"msg" => "nic cannot take part in rekey"})
    end

    it "continues when the host is down but reachable" do
      Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "unavailable")
      expect(vm_host.sshable).to receive(:_cmd).with("true").and_return("")
      expect { nx.before_run }.not_to exit
    end

    it "continues without probing a host that is up" do
      Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "wait")
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#setup_inbound" do
    before do
      allow(tunnel.src_nic).to receive(:dst_ipsec_tunnels).and_return([tunnel])
      allow(tunnel.src_nic.vm).to receive_messages(ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"), inhost_name: "hellovm")
      allow(tunnel.dst_nic.vm).to receive(:ephemeral_net6).and_return(NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"))
    end

    it "inbound_setup creates states and policies if not exist" do
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir fwd").and_return("")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy add src 10.0.0.1/32 dst 10.0.0.2/32 dir fwd tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 0 mode tunnel").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir fwd").and_return("")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy add src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir fwd tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 0 mode tunnel").and_return(true)
      expect { nx.setup_inbound }.to exit({"msg" => "inbound_setup is complete"})
    end

    it "skips policies if they exist" do
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir fwd").and_return("not_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir fwd").and_return("not_empty")
      expect { nx.setup_inbound }.to exit({"msg" => "inbound_setup is complete"})
    end

    it "creates states with the esn flag when the rekey payload sets esn" do
      tunnel.src_nic.update(rekey_payload: {"reqid" => 86879, "spi4" => "0xe2222222", "spi6" => "0xe3333333", "esn" => true})
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 flag esn replay-window 4096 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 flag esn replay-window 4096", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir fwd").and_return("not_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir fwd").and_return("not_empty")
      expect { nx.setup_inbound }.to exit({"msg" => "inbound_setup is complete"})
    end

    it "skips tunnel if its src_nic doesn't have rekey_payload" do
      expect(tunnel.src_nic).to receive(:rekey_payload).and_return(nil)
      expect { nx.setup_inbound }.to exit({"msg" => "inbound_setup is complete"})
    end
  end

  describe "#setup_outbound" do
    before do
      allow(tunnel.src_nic).to receive(:src_ipsec_tunnels).and_return([tunnel])
      allow(tunnel.src_nic.vm).to receive_messages(ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"), inhost_name: "hellovm")
      allow(tunnel.dst_nic.vm).to receive(:ephemeral_net6).and_return(NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"))
    end

    it "creates new state and policy for src" do
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579")
      # If state exists, silently skips
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_raise Sshable::SshError.new("", "", "File exists", nil, nil)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir out").and_return("non_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy update src 10.0.0.1/32 dst 10.0.0.2/32 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 86879 mode tunnel")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out").and_return("non_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy update src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 86879 mode tunnel")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm route replace fd10:9b0b:6b4b:8fbb:def::/128 dev vethihellovm")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm route replace 10.0.0.2/32 dev vethihellovm")
      expect { nx.setup_outbound }.to exit({"msg" => "outbound_setup is complete"})
    end

    it "raises error if state creation fails" do
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_raise Sshable::SshError.new("", "", "bogus", nil, nil)
      expect { nx.setup_outbound }.to raise_error(Sshable::SshError)
    end

    it "skips tunnel if its src_nic doesn't have rekey_payload" do
      expect(tunnel.src_nic).to receive(:rekey_payload).and_return(nil)
      expect { nx.setup_outbound }.to exit({"msg" => "outbound_setup is complete"})
    end

    it "keeps the existing policies toward a nic outside the rekey pass" do
      tunnel.dst_nic.update(rekey_payload: nil)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir out").and_return("non_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out").and_return("non_empty")
      expect { nx.setup_outbound }.to exit({"msg" => "outbound_setup is complete"})
    end

    it "creates state and policies toward a nic outside the rekey pass that has none" do
      tunnel.dst_nic.update(rekey_payload: nil)
      sshable = tunnel.src_nic.vm.vm_host.sshable
      expect(sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir out").and_return("").twice
      expect(sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579")
      expect(sshable).to receive(:_cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579")
      expect(sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy add src 10.0.0.1/32 dst 10.0.0.2/32 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 86879 mode tunnel")
      expect(sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out").and_return("")
      expect(sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm policy add src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 86879 mode tunnel")
      expect(sshable).to receive(:_cmd).with("sudo ip -n hellovm route replace fd10:9b0b:6b4b:8fbb:def::/128 dev vethihellovm")
      expect(sshable).to receive(:_cmd).with("sudo ip -n hellovm route replace 10.0.0.2/32 dev vethihellovm")
      expect { nx.setup_outbound }.to exit({"msg" => "outbound_setup is complete"})
    end

    it "skips a peer that has no vm" do
      vmless_nic = Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:456::", private_ipv4: "10.0.0.4", mac: "00:00:00:00:00:00", name: "vmless-nic", state: "initializing")
      vmless_tunnel = IpsecTunnel.create(src_nic_id: tunnel.src_nic.id, dst_nic_id: vmless_nic.id)
      allow(tunnel.src_nic).to receive(:src_ipsec_tunnels).and_return([vmless_tunnel])
      expect { nx.setup_outbound }.to exit({"msg" => "outbound_setup is complete"})
    end
  end

  describe "#drop_old_state" do
    let(:states_data) {
      "src 2a01:4f8:10a:128b:7537:: dst 2a01:4f8:10a:128b:4919::
proto esp spi 0xe3333333 reqid 49966 mode tunnel
replay-window 0
aead rfc4106(gcm(aes)) 0x6c838df72ba3abe1a2643ee104e21d617830f1b765addced5e26d17a4cc5048d1468ac54 128
anti-replay context: seq 0x0, oseq 0x0, bitmap 0x00000000
sel src ::/0 dst ::/0
src 2a01:4f8:10a:128b:7537:: dst 2a01:4f8:10a:128b:4919::
proto esp spi 0xe2222222 reqid 49966 mode tunnel
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
      expect(tunnel.src_nic.vm).to receive(:inhost_name).and_return("hellovm").at_least(:once)
    end

    it "drops old states and pops" do
      expect(tunnel.src_nic).to receive(:dst_ipsec_tunnels).and_return([tunnel]).at_least(:once)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state", log: :on_error).and_return(states_data)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x610a9eb5").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x059e11e6").and_return(true)
      expect { nx.drop_old_state }.to exit({"msg" => "drop_old_state is complete"})
    end

    it "skips if there is no tunnel" do
      expect(tunnel.src_nic).to receive(:src_ipsec_tunnels).and_return([])
      expect(tunnel.src_nic).to receive(:dst_ipsec_tunnels).and_return([])
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state deleteall")
      expect { nx.drop_old_state }.to exit({"msg" => "drop_old_state is complete early"})
    end

    it "keeps the states shared with a peer outside the rekey pass" do
      outside_vm = create_vm(name: "outsidevm", vm_host_id: tunnel.src_nic.vm.vm_host_id, ephemeral_net6: "2a01:4f8:10a:0:1536::/79")
      outside_nic = Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:123::", private_ipv4: "10.0.0.3", mac: "00:00:00:00:00:00", name: "outside-nic", vm_id: outside_vm.id, state: "active")
      IpsecTunnel.create(src_nic_id: tunnel.src_nic.id, dst_nic_id: outside_nic.id)
      IpsecTunnel.create(src_nic_id: outside_nic.id, dst_nic_id: tunnel.src_nic.id)
      # NetAddr#to_s gives 2a01:4f8:10a:0:1537:0:0:0 for the outside tunnel address
      states = <<~STATES
        src 2a01:4f8:10a:0:1537:: dst 2a01:4f8:10a:128b:4919::
        \tproto esp spi 0x11111111 reqid 1 mode tunnel
        src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:0:1537::
        \tproto esp spi 0x22222222 reqid 2 mode tunnel
        src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537::
        \tproto esp spi 0x22222222 reqid 2 mode tunnel
      STATES
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state", log: :on_error).and_return(states)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x22222222").and_return(true)
      expect { nx.drop_old_state }.to exit({"msg" => "drop_old_state is complete"})
    end

    it "drops the states of a peer outside the rekey pass that has no vm" do
      vmless_nic = Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:456::", private_ipv4: "10.0.0.4", mac: "00:00:00:00:00:00", name: "vmless-nic", state: "initializing")
      IpsecTunnel.create(src_nic_id: tunnel.src_nic.id, dst_nic_id: vmless_nic.id)
      IpsecTunnel.create(src_nic_id: vmless_nic.id, dst_nic_id: tunnel.src_nic.id)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state", log: :on_error).and_return(states_data)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x610a9eb5").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:_cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x059e11e6").and_return(true)
      expect { nx.drop_old_state }.to exit({"msg" => "drop_old_state is complete"})
    end
  end
end
