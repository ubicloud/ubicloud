# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::HetznerServer do
  subject(:hs_test) {
    expect(Config).to receive(:ci_hetzner_sacrificial_server_id).and_return("1.1.1.1")
    described_class.new(described_class.assemble)
  }

  let(:hetzner_api) {
    instance_double(Hosting::HetznerApis)
  }

  let(:sshable) {
    Sshable.create_with_id
  }

  before {
    vm_host = VmHost.create(location: "l") { _1.id = sshable.id }
    Strand.create(prog: "Prog", label: "label") { _1.id = sshable.id }
    allow(hs_test).to receive_messages(frame: {"vm_host_id" => vm_host.id,
                                               "hetzner_ssh_keypair" => "oOtAbOGFVHJjFyeQBgSfghi+YBuyQzBRsKABGZhOmDpmwxqx681mscsGBLaQ\n2iWQsOYBBVLDtQWe/gf3NRNyBw==\n",
                                               "server_id" => "1234"}, hetzner_api: hetzner_api)
  }

  describe "#assemble" do
    it "fails if CI_HETZNER_SACRIFICIAL_SERVER_ID not provided" do
      expect(Config).to receive(:ci_hetzner_sacrificial_server_id).and_return("")
      expect { described_class.assemble }.to raise_error RuntimeError, "CI_HETZNER_SACRIFICIAL_SERVER_ID must be a nonempty string"
    end
  end

  describe "#start" do
    it "hops to setup_vms" do
      expect { hs_test.start }.to hop("fetch_hostname", "Test::HetznerServer")
    end
  end

  describe "#fetch_hostname" do
    it "can fetch hostname" do
      expect(hetzner_api).to receive(:get_main_ip4)
      expect { hs_test.fetch_hostname }.to hop("add_ssh_key", "Test::HetznerServer")
    end
  end

  describe "#add_ssh_key" do
    it "can add ssh key" do
      expect(hetzner_api).to receive(:add_key)
      expect { hs_test.add_ssh_key }.to hop("reset", "Test::HetznerServer")
    end
  end

  describe "#reset" do
    it "can reset" do
      expect(hetzner_api).to receive(:reset).with("1234", hetzner_ssh_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGbDGrHrzWaxywYEtpDaJZCw5gEFUsO1BZ7+B/c1E3IH")
      expect { hs_test.reset }.to hop("wait_reset", "Test::HetznerServer")
    end
  end

  describe "#wait_reset" do
    it "hops to setup_host if children idle" do
      expect(Util).to receive(:rootish_ssh)
      expect { hs_test.wait_reset }.to hop("setup_host", "Test::HetznerServer")
    end

    it "donates if children not idle" do
      expect(Util).to receive(:rootish_ssh).and_raise RuntimeError, "ssh failed"
      expect { hs_test.wait_reset }.to nap(15)
    end
  end

  describe "#setup_host" do
    it "hops to wait_setup_host" do
      allow(Prog::Vm::HostNexus).to receive(:assemble).and_return(Strand[sshable.id])
      expect { hs_test.setup_host }.to hop("wait_setup_host", "Test::HetznerServer")
    end
  end

  describe "#wait_setup_host" do
    it "hops to test_host_encrypted if children idle" do
      expect(hs_test).to receive(:children_idle).and_return(true)
      expect { hs_test.wait_setup_host }.to hop("test_host_encrypted", "Test::HetznerServer")
    end

    it "donates if children not idle" do
      expect(hs_test).to receive(:children_idle).and_return(false)
      expect { hs_test.wait_setup_host }.to nap(0)
    end
  end

  describe "#test_host_encrypted" do
    it "hops to wait_test_host_encrypted" do
      expect { hs_test.test_host_encrypted }.to hop("wait_test_host_encrypted", "Test::HetznerServer")
    end
  end

  describe "#wait_test_host_encrypted" do
    it "hops to test_host_unencrypted if children idle" do
      expect(hs_test).to receive(:children_idle).and_return(true)
      expect { hs_test.wait_test_host_encrypted }.to hop("test_host_unencrypted", "Test::HetznerServer")
    end

    it "donates if children not idle" do
      expect(hs_test).to receive(:children_idle).and_return(false)
      expect { hs_test.wait_test_host_encrypted }.to nap(0)
    end
  end

  describe "#test_host_unencrypted" do
    it "hops to wait_test_host_unencrypted" do
      expect { hs_test.test_host_unencrypted }.to hop("wait_test_host_unencrypted", "Test::HetznerServer")
    end
  end

  describe "#wait_test_host_unencrypted" do
    it "hops to delete_key if children idle" do
      expect(hs_test).to receive(:children_idle).and_return(true)
      expect { hs_test.wait_test_host_unencrypted }.to hop("delete_key", "Test::HetznerServer")
    end

    it "donates if children not idle" do
      expect(hs_test).to receive(:children_idle).and_return(false)
      expect { hs_test.wait_test_host_unencrypted }.to nap(0)
    end
  end

  describe "#delete_key" do
    it "deletes key" do
      expect(hetzner_api).to receive(:delete_key).with("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGbDGrHrzWaxywYEtpDaJZCw5gEFUsO1BZ7+B/c1E3IH")
      expect { hs_test.delete_key }.to hop("finish", "Test::HetznerServer")
    end
  end

  describe "#finish" do
    it "exits" do
      expect { hs_test.finish }.to exit({"msg" => "HetznerServer tests finished!"})
    end
  end

  describe "#children_idle" do
    it "returns true if no children" do
      st = Strand.create_with_id(prog: "Prog", label: "label")
      allow(hs_test).to receive(:strand).and_return(st)
      expect(hs_test.children_idle).to be(true)
    end
  end

  describe "#hetzner_api" do
    it "can create a HetznerApis instance" do
      allow(hs_test).to receive(:hetzner_api).and_call_original
      expect(hs_test.hetzner_api).not_to be_nil
    end
  end
end
