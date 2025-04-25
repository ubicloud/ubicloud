# frozen_string_literal: true

RSpec.describe Prog::Vnet::RekeyNicTunnel do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    PrivateSubnet.create_with_id(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: Project.create(name: "test").id)
  }
  let(:tunnel) {
    sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
    vmh = VmHost.create(location_id: Location::HETZNER_FSN1_ID) { it.id = sa.id }
    vm_src = create_vm(name: "hellovm", vm_host_id: vmh.id)
    vm_dst = create_vm(name: "hellovm2", vm_host_id: vmh.id)
    n_src = Nic.create_with_id(private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
      private_ipv4: "10.0.0.1",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic",
      rekey_payload: {"reqid" => 86879, "spi4" => "0xe2222222", "spi6" => "0xe3333333"},
      vm_id: vm_src.id)
    n_dst = Nic.create_with_id(private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:def::",
      private_ipv4: "10.0.0.2",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic",
      rekey_payload: {"reqid" => 14329, "spi4" => "0xe0000000", "spi6" => "0xe1111111"},
      vm_id: vm_dst.id)
    IpsecTunnel.create_with_id(src_nic_id: n_src.id, dst_nic_id: n_dst.id).tap { it.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
  }

  before do
    nx.instance_variable_set(:@nic, tunnel.src_nic)
  end

  describe "#before_run" do
    it "pops when destroy is set" do
      Strand.create(prog: "Vnet:NicNexus", label: "wait_vm") { it.id = tunnel.src_nic.id }
      tunnel.src_nic.incr_destroy
      expect { nx.before_run }.to exit({"msg" => "nic.destroy semaphore is set"})
    end

    it "doesn't do anything if destroy is not set" do
      expect { nx.before_run }.not_to exit({"msg" => "nic.destroy semaphore is set"})
    end
  end

  describe "#setup_inbound" do
    before do
      allow(tunnel.src_nic).to receive(:dst_ipsec_tunnels).and_return([tunnel])
      allow(tunnel.src_nic.vm).to receive_messages(ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"), inhost_name: "hellovm")
      allow(tunnel.dst_nic.vm).to receive(:ephemeral_net6).and_return(NetAddr.parse_net("2a01:4f8:10a:128b:4919::/80"))
    end

    it "inbound_setup creates states and policies if not exist" do
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 ", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir fwd").and_return("")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy add src 10.0.0.1/32 dst 10.0.0.2/32 dir fwd tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 0 mode tunnel").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir fwd").and_return("")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy add src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir fwd tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 0 mode tunnel").and_return(true)
      expect { nx.setup_inbound }.to exit({"msg" => "inbound_setup is complete"})
    end

    it "skips policies if they exist" do
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 ", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir fwd").and_return("not_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir fwd").and_return("not_empty")
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
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579")
      # If state exists, silently skips
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 ", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_raise Sshable::SshError.new("", "", "File exists", nil, nil)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy show src 10.0.0.1/32 dst 10.0.0.2/32 dir out").and_return("non_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy update src 10.0.0.1/32 dst 10.0.0.2/32 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 86879 mode tunnel")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy show src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out").and_return("non_empty")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm policy update src fd10:9b0b:6b4b:8fbb:abc::/128 dst fd10:9b0b:6b4b:8fbb:def::/128 dir out tmpl src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp reqid 86879 mode tunnel")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm route replace fd10:9b0b:6b4b:8fbb:def::/128 dev vethihellovm")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm route replace 10.0.0.2/32 dev vethihellovm")
      expect { nx.setup_outbound }.to exit({"msg" => "outbound_setup is complete"})
    end

    it "raises error if state creation fails" do
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe2222222 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 sel src 0.0.0.0/0 dst 0.0.0.0/0", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579")
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo -- xargs -I {} -- ip -n hellovm xfrm state add src 2a01:4f8:10a:128b:4919:8000:: dst 2a01:4f8:10a:128b:4919:8000:: proto esp spi 0xe3333333 reqid 86879 mode tunnel aead 'rfc4106(gcm(aes))' {} 128 ", stdin: "0x736f6d655f656e6372797074696f6e5f6b6579").and_raise Sshable::SshError.new("", "", "bogus", nil, nil)
      expect { nx.setup_outbound }.to raise_error(Sshable::SshError)
    end

    it "skips tunnel if its src_nic doesn't have rekey_payload" do
      expect(tunnel.src_nic).to receive(:rekey_payload).and_return(nil)
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
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm state").and_return(states_data)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x610a9eb5").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x059e11e6").and_return(true)
      expect { nx.drop_old_state }.to exit({"msg" => "drop_old_state is complete"})
    end

    it "skips if there is no tunnel" do
      expect(tunnel.src_nic).to receive(:src_ipsec_tunnels).and_return([])
      expect(tunnel.src_nic).to receive(:dst_ipsec_tunnels).and_return([])
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm state deleteall")
      expect { nx.drop_old_state }.to exit({"msg" => "drop_old_state is complete early"})
    end

    it "skips if the dst tunnel nic is not rekeying" do
      src_nic = instance_double(Nic, rekey_payload: nil)
      not_rekeying_nic_tun = instance_double(IpsecTunnel, src_nic: src_nic)
      expect(tunnel.src_nic).to receive(:dst_ipsec_tunnels).and_return([not_rekeying_nic_tun])
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm state").and_return(states_data)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x610a9eb5").and_return(true)
      expect(tunnel.src_nic.vm.vm_host.sshable).to receive(:cmd).with("sudo ip -n hellovm xfrm state delete src 2a01:4f8:10a:128b:4919:: dst 2a01:4f8:10a:128b:7537:: proto esp spi 0x059e11e6").and_return(true)
      expect { nx.drop_old_state }.to exit({"msg" => "drop_old_state is complete"})
    end
  end
end
