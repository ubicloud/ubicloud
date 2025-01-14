# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::HetznerServer do
  subject(:hs_test) { described_class.new(described_class.assemble) }

  let(:hetzner_api) { instance_double(Hosting::HetznerApis) }
  let(:vm_host) { Prog::Vm::HostNexus.assemble("1.1.1.1").subject }

  before {
    allow(Config).to receive(:ci_hetzner_sacrificial_server_id).and_return("1.1.1.1")
    allow(hs_test).to receive_messages(frame: {"vm_host_id" => vm_host.id,
                                               "hetzner_ssh_keypair" => "oOtAbOGFVHJjFyeQBgSfghi+YBuyQzBRsKABGZhOmDpmwxqx681mscsGBLaQ\n2iWQsOYBBVLDtQWe/gf3NRNyBw==\n",
                                               "server_id" => "1234",
                                               "setup_host" => true}, hetzner_api: hetzner_api, vm_host: vm_host)
  }

  describe "#assemble" do
    it "fails if CI_HETZNER_SACRIFICIAL_SERVER_ID not provided" do
      expect(Config).to receive(:ci_hetzner_sacrificial_server_id).and_return("")
      expect { described_class.assemble }.to raise_error RuntimeError, "CI_HETZNER_SACRIFICIAL_SERVER_ID must be a nonempty string"
    end

    it "uses exiting vm host if given" do
      HetznerHost.create(server_identifier: "1234") { _1.id = vm_host.id }
      st = described_class.assemble(vm_host_id: vm_host.id)
      expect(st.stack.first["vm_host_id"]).to eq(vm_host.id)
      expect(st.stack.first["hostname"]).to eq("1.1.1.1")
      expect(st.stack.first["setup_host"]).to be(false)
    end
  end

  describe "#start" do
    it "hops to fetch_hostname if setup_host is true" do
      expect(hs_test).to receive(:frame).and_return({"setup_host" => true})
      expect { hs_test.start }.to hop("fetch_hostname")
    end

    it "hops to wait_setup_host if vm_host_id is given" do
      expect(hs_test).to receive(:frame).and_return({"vm_host_id" => "123"})
      expect { hs_test.start }.to hop("wait_setup_host")
    end
  end

  describe "#fetch_hostname" do
    it "can fetch hostname" do
      expect(hetzner_api).to receive(:get_main_ip4)
      expect { hs_test.fetch_hostname }.to hop("reimage")
    end
  end

  describe "#reimage" do
    it "can reimage" do
      expect(hetzner_api).to receive(:reimage).with("1234", dist: "Ubuntu 24.04 LTS base")
      expect { hs_test.reimage }.to hop("wait_reimage")
    end
  end

  describe "#wait_reimage" do
    it "hops to setup_host if the server is up" do
      expect(Util).to receive(:rootish_ssh)
      expect { hs_test.wait_reimage }.to hop("setup_host")
    end

    it "naps if the server is not up yet" do
      expect(Util).to receive(:rootish_ssh).and_raise RuntimeError, "ssh failed"
      expect { hs_test.wait_reimage }.to nap(15)
    end
  end

  describe "#setup_host" do
    it "hops to wait_setup_host" do
      expect(Prog::Vm::HostNexus).to receive(:assemble).and_return(vm_host.strand)
      expect { hs_test.setup_host }.to hop("wait_setup_host")
    end
  end

  describe "#wait_setup_host" do
    it "naps if the vm host is not ready yet" do
      expect(vm_host.strand).to receive(:label).and_return("wait_prep")
      expect { hs_test.wait_setup_host }.to nap(15)
    end

    it "hops to run_integration_specs if rhizome installed" do
      expect(vm_host.strand).to receive(:label).and_return("wait")
      expect(hs_test).to receive(:retval).and_return({"msg" => "installed rhizome"})
      expect(hs_test).to receive(:verify_specs_installation).with(installed: true)
      expect { hs_test.wait_setup_host }.to hop("run_integration_specs")
    end

    it "verifies specs haven't been installed when we setup the host & installs rhizome with specs" do
      expect(hs_test).to receive(:frame).and_return({"setup_host" => true})
      expect(vm_host.strand).to receive(:label).and_return("wait")
      expect(hs_test).to receive(:verify_specs_installation).with(installed: false)
      expect { hs_test.wait_setup_host }.to hop("start", "InstallRhizome")
    end

    it "doesn't verify specs not installed if we didn't setup the host" do
      expect(hs_test).to receive(:frame).and_return({"setup_host" => false})
      expect(vm_host.strand).to receive(:label).and_return("wait")
      expect(hs_test).not_to receive(:verify_specs_installation)
      expect { hs_test.wait_setup_host }.to hop("start", "InstallRhizome")
    end
  end

  describe "#verify_specs_installation" do
    it "succeeds when installed=false & not exists" do
      expect(hs_test.vm_host.sshable).to receive(:cmd).and_return("0\n")
      expect { hs_test.verify_specs_installation(installed: false) }.not_to raise_error
    end

    it "succeeds when installed=true & exists" do
      expect(hs_test.vm_host.sshable).to receive(:cmd).and_return("5\n")
      expect { hs_test.verify_specs_installation(installed: true) }.not_to raise_error
    end

    it "succeeds when installed=false & exists" do
      expect(hs_test.vm_host.sshable).to receive(:cmd).and_return("5\n")
      expect(hs_test).to receive(:fail_test).with("verify_specs_installation(installed: false) failed")
      hs_test.verify_specs_installation(installed: false)
    end
  end

  describe "#run_integration_specs" do
    it "hops to wait" do
      tmp_dir = "/var/storage/tests"
      expect(hs_test.vm_host.sshable).to receive(:cmd).with("sudo mkdir -p #{tmp_dir}")
      expect(hs_test.vm_host.sshable).to receive(:cmd).with("sudo chmod a+rw #{tmp_dir}")
      expect(hs_test.vm_host.sshable).to receive(:cmd).with(
        "sudo RUN_E2E_TESTS=1 SPDK_TESTS_TMP_DIR=#{tmp_dir} bundle exec rspec host/e2e"
      )
      expect { hs_test.run_integration_specs }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to destroy when needed" do
      expect(hs_test).to receive(:when_destroy_set?).and_yield
      expect { hs_test.wait }.to hop("destroy")
    end

    it "naps" do
      expect { hs_test.wait }.to nap(15)
    end
  end

  describe "#destroy" do
    it "does not delete key and vm host if existing vm host used" do
      expect(hs_test).to receive(:frame).and_return({"destroy" => false})
      expect { hs_test.destroy }.to hop("finish")
    end

    it "deletes vm host" do
      expect(hs_test).to receive(:frame).and_return({"setup_host" => true})
      expect(vm_host).to receive(:incr_destroy)
      expect { hs_test.destroy }.to hop("wait_vm_host_destroyed")
    end
  end

  describe "#wait_vm_host_destroyed" do
    it "naps if the vm host isn't deleted yet" do
      expect(hs_test).to receive(:vm_host).and_return(vm_host)
      expect { hs_test.wait_vm_host_destroyed }.to nap(10)
    end

    it "hops to finish if the vm host destroyed" do
      expect(hs_test).to receive(:vm_host).and_return(nil)
      expect { hs_test.wait_vm_host_destroyed }.to hop("finish")
    end
  end

  describe "#finish" do
    it "exits" do
      expect { hs_test.finish }.to exit({"msg" => "HetznerServer tests finished!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { hs_test.failed }.to nap(15)
    end
  end

  describe "#hetzner_api" do
    it "can create a HetznerApis instance" do
      allow(hs_test).to receive(:hetzner_api).and_call_original
      expect(hs_test.hetzner_api).not_to be_nil
    end
  end

  describe "#vm_host" do
    it "returns the vm_host" do
      prg = described_class.new(Strand.new(stack: [{"vm_host_id" => "123"}]))
      vmh = instance_double(VmHost)
      expect(VmHost).to receive(:[]).with("123").and_return(vmh)
      expect(prg.vm_host).to eq(vmh)
    end
  end
end
