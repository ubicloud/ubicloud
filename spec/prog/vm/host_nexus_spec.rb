# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::HostNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { described_class.assemble("192.168.0.1") }
  let(:hetzner_ips) {
    [
      ["127.0.0.1", "127.0.0.1", false],
      ["30.30.30.32/29", "127.0.0.1", true],
      ["2a01:4f8:10a:128b::/64", "127.0.0.1", true]
    ].map {
      Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
    }
  }

  let(:sshable) { create_mock_sshable(raw_private_key_1: "bogus") }
  let(:vm_host) { st.subject }

  # Helper to create VMs associated with vm_host
  def create_test_vm(memory_gib:)
    project = Project.create(name: "test-project-#{SecureRandom.hex(4)}")
    ps = PrivateSubnet.create(
      name: "test-ps", project_id: project.id, location_id: vm_host.location_id,
      net4: "10.0.0.0/26", net6: "fd10:9b0b:6b4b:8fbb::/64"
    )
    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "test-vm-#{SecureRandom.hex(4)}", private_subnet_id: ps.id,
      location_id: vm_host.location_id, force_host_id: vm_host.id
    )
    vm = vm_st.subject
    vm.update(vm_host_id: vm_host.id, memory_gib: memory_gib)
    vm
  end

  # Helper to create SpdkInstallation for vm_host
  def create_test_spdk(cpu_count: 4, hugepages: 4, version: "v1.0")
    si = SpdkInstallation.create(
      vm_host_id: vm_host.id, version: version, allocation_weight: 100
    )
    si.update(cpu_count: cpu_count, hugepages: hugepages)
    si
  end

  # Helper to create VmHostSlice for vm_host
  def create_test_slice(name:, total_memory_gib:, cores: 4)
    VmHostSlice.create(
      vm_host_id: vm_host.id, name: name, family: "standard",
      cores: cores, total_cpu_percent: cores * 100, used_cpu_percent: 0,
      total_memory_gib: total_memory_gib, used_memory_gib: 0
    )
  end

  before do
    allow(nx).to receive(:sshable).and_return(sshable)
    allow(sshable).to receive(:start_fresh_session).and_return(Net::SSH::Connection::Session.allocate)
  end

  describe ".assemble" do
    it "fails if location doesn't exist" do
      expect {
        described_class.assemble("127.0.0.1", location_id: nil)
      }.to raise_error RuntimeError, "No existing Location"
    end

    it "creates addresses properly for a regular host" do
      st = described_class.assemble("127.0.0.1")
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.subject.assigned_subnets.count).to eq(1)
      expect(st.subject.assigned_subnets.first.cidr.to_s).to eq("127.0.0.1/32")

      expect(st.subject.assigned_host_addresses.count).to eq(1)
      expect(st.subject.assigned_host_addresses.first.ip.to_s).to eq("127.0.0.1/32")
      expect(st.subject.provider).to be_nil
    end

    it "creates addresses properly and sets the server name for a hetzner host" do
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
      expect(Hosting::Apis).to receive(:pull_data_center).and_return("fsn1-dc14")
      expect(Hosting::Apis).to receive(:set_server_name).and_return(nil)
      st = described_class.assemble("127.0.0.1", provider_name: HostProvider::HETZNER_PROVIDER_NAME, server_identifier: "1")
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.subject.assigned_subnets.count).to eq(3)
      expect(st.subject.assigned_subnets.map { it.cidr.to_s }.sort).to eq(["127.0.0.1/32", "30.30.30.32/29", "2a01:4f8:10a:128b::/64"].sort)

      expect(st.subject.assigned_host_addresses.count).to eq(1)
      expect(st.subject.assigned_host_addresses.first.ip.to_s).to eq("127.0.0.1/32")
      expect(st.subject.provider_name).to eq(HostProvider::HETZNER_PROVIDER_NAME)
      expect(st.subject.data_center).to eq("fsn1-dc14")
    end

    it "does not set the server name in development" do
      expect(Config).to receive(:development?).and_return(true)
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
      expect(Hosting::Apis).to receive(:pull_data_center).and_return("fsn1-dc14")
      expect(Hosting::Apis).not_to receive(:set_server_name)

      described_class.assemble("127.0.0.1", provider_name: HostProvider::HETZNER_PROVIDER_NAME, server_identifier: "1")
    end

    it "checks whether both spdk and vhost_block_backend version is set" do
      expect { described_class.assemble("127.0.0.1", vhost_block_backend_version: "someversion") }.to raise_error("SPDK and VhostBlockBackend cannot be set simultaneously")
    end

    it "checks that both spdk and vhost_block_backend version is set although one is nil" do
      st = described_class.assemble("127.0.0.1", spdk_version: nil, vhost_block_backend_version: "someversion")
      expect(st.stack.first["spdk_version"]).to be_nil
      expect(st.stack.first["vhost_block_backend_version"]).to eq("someversion")

      st = described_class.assemble("1.2.3.4")
      expect(st.stack.first["spdk_version"]).to eq(Config.spdk_version)
      expect(st.stack.first["vhost_block_backend_version"]).to be_nil
    end
  end

  describe "#start" do
    it "hops to setup_ssh_keys" do
      expect { nx.start }.to hop("setup_ssh_keys")
    end
  end

  describe "#setup_ssh_keys" do
    it "generates a keypair if one is not set" do
      expect(Config).to receive(:hetzner_ssh_private_key).and_return(nil)
      expect(sshable).to receive(:raw_private_key_1).and_return(nil)
      expect(sshable).to receive(:update) do |**args|
        key = args[:raw_private_key_1]
        expect(key).to be_instance_of String
        expect(key.length).to eq 64
      end

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
    end

    it "does not generate a keypair if one is already set" do
      expect(Config).to receive(:hetzner_ssh_private_key).and_return(nil)
      expect(sshable).to receive(:raw_private_key_1).and_return("bogus")
      expect(sshable).not_to receive(:update)
      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
    end

    it "skips if private key is not set" do
      expect(Config).to receive(:hetzner_ssh_private_key).and_return(nil)
      expect(Net::SSH).not_to receive(:start)

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
    end

    it "adds a public key if private key is set" do
      root_key = SshKey.generate
      vmhost_key = SshKey.generate
      test_public_keys = vmhost_key.public_key.to_s

      expect(Config).to receive(:hetzner_ssh_private_key).exactly(2).and_return(root_key.private_key)
      expect(Config).to receive(:operator_ssh_public_keys).and_return(nil)
      expect(sshable).to receive(:keys).and_return([vmhost_key])
      expect(sshable).to receive(:host).and_return("127.0.0.1")
      session = Net::SSH::Connection::Session.allocate
      expect(Net::SSH).to receive(:start).and_yield(session)
      expect(session).to receive(:_exec!).with("echo #{test_public_keys.gsub(" ", "\\ ")} > ~/.ssh/authorized_keys").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
    end

    it "adds operational keys if set" do
      root_key = SshKey.generate
      vmhost_key = SshKey.generate
      operational_key_1 = SshKey.generate
      operational_key_2 = SshKey.generate
      test_public_keys = "#{vmhost_key.public_key}\n#{operational_key_1.public_key}\n#{operational_key_2.public_key}"

      expect(Config).to receive(:hetzner_ssh_private_key).exactly(2).and_return(root_key.private_key)
      expect(Config).to receive(:operator_ssh_public_keys).exactly(2).and_return("#{operational_key_1.public_key}\n#{operational_key_2.public_key}")
      expect(sshable).to receive(:keys).and_return([vmhost_key])
      expect(sshable).to receive(:host).and_return("127.0.0.1")
      session = Net::SSH::Connection::Session.allocate
      expect(Net::SSH).to receive(:start).and_yield(session)
      expect(session).to receive(:_exec!).with("echo #{test_public_keys.gsub(" ", "\\ ").gsub("\n", "'\n'")} > ~/.ssh/authorized_keys").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "pushes a bootstrap rhizome process" do
      expect(nx).to receive(:push).with(Prog::BootstrapRhizome, {"target_folder" => "host"}).and_call_original
      expect { nx.bootstrap_rhizome }.to hop("start", "BootstrapRhizome")
    end

    it "hops once BootstrapRhizome has returned" do
      nx.strand.retval = {"msg" => "rhizome user bootstrapped and source installed"}
      expect { nx.bootstrap_rhizome }.to hop("prep")
    end
  end

  describe "#prep" do
    it "starts a number of sub-programs" do
      vm_host.update(net6: "2a01:4f9:2b:35a::/64")
      budded = []
      expect(nx).to receive(:bud) do
        budded << it
      end.at_least(:once)

      expect { nx.prep }.to hop("wait_prep")

      expect(budded).to eq([
        Prog::Vm::PrepHost,
        Prog::LearnMemory,
        Prog::LearnOs,
        Prog::LearnCpu,
        Prog::LearnStorage,
        Prog::LearnPci,
        Prog::InstallDnsmasq,
        Prog::SetupSysstat,
        Prog::SetupNftables,
        Prog::SetupNodeExporter
      ])
    end

    it "learns the network from the host if it is not set a-priori" do
      # vm_host.net6 is nil by default
      budded_learn_network = false
      expect(nx).to receive(:bud) do
        budded_learn_network ||= (it == Prog::LearnNetwork)
      end.at_least(:once)

      expect { nx.prep }.to hop("wait_prep")

      expect(budded_learn_network).to be true
    end
  end

  describe "#os_supports_slices?" do
    it "returns true if the OS supports slices" do
      expect(nx.os_supports_slices?("ubuntu-22.04")).to be false
      expect(nx.os_supports_slices?("ubuntu-24.04")).to be true
    end
  end

  describe "#wait_prep" do
    it "updates the vm_host record from the finished programs" do
      Strand.create(parent_id: st.id, prog: "LearnMemory", label: "start", stack: [{}], exitval: {"mem_gib" => 1})
      Strand.create(parent_id: st.id, prog: "LearnOs", label: "start", stack: [{}], exitval: {"os_version" => "ubuntu-24.04"})
      Strand.create(parent_id: st.id, prog: "LearnCpu", label: "start", stack: [{}], exitval: {"arch" => "arm64", "total_sockets" => 2, "total_dies" => 3, "total_cores" => 4, "total_cpus" => 5})
      Strand.create(parent_id: st.id, prog: "ArbitraryOtherProg", label: "start", stack: [{}], exitval: {})

      expect { nx.wait_prep }.to hop("setup_hugepages")

      vm_host.reload
      expect(vm_host.total_mem_gib).to eq 1
      expect(vm_host.os_version).to eq "ubuntu-24.04"
      expect(vm_host.arch).to eq "arm64"
      expect(vm_host.total_cores).to eq 4
      expect(vm_host.total_cpus).to eq 5
      expect(vm_host.total_dies).to eq 3
      expect(vm_host.total_sockets).to eq 2
      expect(VmHostCpu.where(vm_host_id: vm_host.id).select_order_map([:cpu_number, :spdk])).to eq [[0, true], [1, true], [2, false], [3, false], [4, false]]
    end

    it "crashes if an expected field is not set for LearnMemory" do
      Strand.create(parent_id: st.id, prog: "LearnMemory", label: "start", stack: [{}], exitval: {})
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"mem_gib\""
    end

    it "crashes if an expected field is not set for LearnCpu" do
      Strand.create(parent_id: st.id, prog: "LearnCpu", label: "start", stack: [{}], exitval: {})
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"arch\""
    end

    it "donates to children if they are not exited yet" do
      Strand.create(parent_id: st.id, prog: "LearnCpu", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_prep }.to nap(120)
    end
  end

  describe "#setup_hugepages" do
    it "pushes the hugepage program" do
      expect { nx.setup_hugepages }.to hop("start", "SetupHugepages")
    end

    it "hops once SetupHugepages has returned" do
      nx.strand.retval = {"msg" => "hugepages installed"}
      expect { nx.setup_hugepages }.to hop("setup_storage_backend")
    end
  end

  describe "#setup_storage_backend" do
    it "pushes the spdk program by default" do
      expect(nx).to receive(:push).with(Prog::Storage::SetupSpdk,
        {
          "version" => Config.spdk_version,
          "start_service" => false,
          "allocation_weight" => 100
        }).and_call_original
      expect { nx.setup_storage_backend }.to hop("start", "Storage::SetupSpdk")
    end

    it "pushes the vhost_block_backend program when spdk is not set and vhost_block_backend is set" do
      nx = described_class.new(described_class.assemble("1.2.3.4", spdk_version: nil, vhost_block_backend_version: "someversion"))
      expect(nx).to receive(:push).with(Prog::Storage::SetupVhostBlockBackend,
        {
          "version" => "someversion",
          "allocation_weight" => 100
        }).and_call_original
      expect { nx.setup_storage_backend }.to hop("start", "Storage::SetupVhostBlockBackend")
    end

    it "hops once SetupSpdk has returned" do
      nx.strand.retval = {"msg" => "SPDK was setup"}
      create_test_spdk(cpu_count: 4)
      vm_host.update(total_cores: 48, total_cpus: 96)
      expect { nx.setup_storage_backend }.to hop("download_boot_images")
      expect(vm_host.reload.used_cores).to eq(2)
    end

    it "hops once SetupVhostBlockBackend has returned" do
      nx.strand.retval = {"msg" => "VhostBlockBackend was setup"}
      expect { nx.setup_storage_backend }.to hop("download_boot_images")
    end
  end

  describe "#download_boot_images" do
    it "pushes the download boot image program" do
      expect(nx).to receive(:frame).and_return({"default_boot_images" => ["ubuntu-jammy", "github-ubuntu-2204"]})
      expect(nx).to receive(:bud).with(Prog::DownloadBootImage, {"image_name" => "ubuntu-jammy"})
      expect(nx).to receive(:bud).with(Prog::DownloadBootImage, {"image_name" => "github-ubuntu-2204"})
      expect { nx.download_boot_images }.to hop("wait_download_boot_images")
    end
  end

  describe "#wait_download_boot_images" do
    it "hops to prep_reboot if all tasks are done" do
      expect { nx.wait_download_boot_images }.to hop("prep_reboot")
    end

    it "donates its time if child strands are still running" do
      Strand.create(parent_id: st.id, prog: "DownloadBootImage", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_download_boot_images }.to nap(120)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to prep_graceful_reboot when needed" do
      expect(nx).to receive(:when_graceful_reboot_set?).and_yield
      expect { nx.wait }.to hop("prep_graceful_reboot")
    end

    it "hops to prep_reboot when needed" do
      expect(nx).to receive(:when_reboot_set?).and_yield
      expect { nx.wait }.to hop("prep_reboot")
    end

    it "hops to prep_hardware_reset when needed" do
      expect(nx).to receive(:when_hardware_reset_set?).and_yield
      expect { nx.wait }.to hop("prep_hardware_reset")
    end

    it "hops to configure_metrics when needed" do
      expect(nx).to receive(:when_configure_metrics_set?).and_yield
      expect { nx.wait }.to hop("configure_metrics")
    end

    it "hops to unavailable based on the host's available status" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")

      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#unavailable" do
    it "hops to prep_graceful_reboot when needed" do
      expect(nx).to receive(:when_graceful_reboot_set?).and_yield
      expect { nx.unavailable }.to hop("prep_graceful_reboot")
    end

    it "hops to prep_reboot when needed" do
      expect(nx).to receive(:when_reboot_set?).and_yield
      expect { nx.unavailable }.to hop("prep_reboot")
    end

    it "hops to prep_hardware_reset when needed" do
      expect(nx).to receive(:when_hardware_reset_set?).and_yield
      expect { nx.unavailable }.to hop("prep_hardware_reset")
    end

    it "registers a short deadline if host is unavailable" do
      expect(nx).to receive(:register_deadline).with("wait", 90)
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "hops to wait if host is available" do
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.unavailable }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "updates allocation state and naps" do
      vm_host.update(allocation_state: "accepting")
      expect { nx.destroy }.to nap(5)
      expect(vm_host.reload.allocation_state).to eq("draining")
    end

    it "waits draining" do
      vm_host.update(allocation_state: "draining")
      create_test_vm(memory_gib: 1)
      expect(Clog).to receive(:emit).with("Cannot destroy the vm host with active virtual machines, first clean them up").and_call_original
      expect { nx.destroy }.to nap(15)
    end

    it "deletes and exists" do
      vm_host.update(allocation_state: "draining")
      vm_host_id = vm_host.id
      # Use the real sshable (not the mock) for destroy
      RSpec::Mocks.space.proxy_for(nx).reset
      expect { nx.destroy }.to exit({"msg" => "vm host deleted"})
      expect(VmHost[vm_host_id]).to be_nil
      expect(Sshable[vm_host_id]).to be_nil
    end
  end

  describe "host graceful reboot" do
    it "prep_graceful_reboot sets allocation_state to draining if it is in accepting" do
      vm_host.update(allocation_state: "accepting")
      create_test_vm(memory_gib: 1)
      expect { nx.prep_graceful_reboot }.to nap(30)
      expect(vm_host.reload.allocation_state).to eq("draining")
    end

    it "prep_graceful_reboot does not change allocation_state if it is already draining" do
      vm_host.update(allocation_state: "draining")
      create_test_vm(memory_gib: 1)
      expect { nx.prep_graceful_reboot }.to nap(30)
      expect(vm_host.reload.allocation_state).to eq("draining")
    end

    it "prep_graceful_reboot fails if not in accepting or draining state" do
      # vm_host starts as "unprepared" by default
      expect { nx.prep_graceful_reboot }.to raise_error(RuntimeError)
    end

    it "prep_graceful_reboot transitions to prep_reboot if there are no VMs" do
      vm_host.update(allocation_state: "draining")
      expect { nx.prep_graceful_reboot }.to hop("prep_reboot")
    end

    it "prep_graceful_reboot transitions to nap if there are VMs" do
      vm_host.update(allocation_state: "draining")
      create_test_vm(memory_gib: 1)
      expect { nx.prep_graceful_reboot }.to nap(30)
    end
  end

  describe "configure metrics" do
    it "configures the metrics and hops to wait" do
      # metrics_config is a computed property, not an FK - stub is OK
      metrics_config = {metrics_dir: "/home/rhizome/host/metrics"}
      allow(nx).to receive(:vm_host).and_return(vm_host)
      allow(vm_host).to receive(:metrics_config).and_return(metrics_config)
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/rhizome/host/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/rhizome/host/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/vmhost-metrics.service > /dev/null", stdin: "[Unit]\nDescription=VmHost Metrics Collection\nAfter=network-online.target\n\n[Service]\nType=oneshot\nUser=rhizome\nExecStart=/home/rhizome/common/bin/metrics-collector /home/rhizome/host/metrics\nStandardOutput=journal\nStandardError=journal\n")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/vmhost-metrics.timer > /dev/null", stdin: "[Unit]\nDescription=Run VmHost Metrics Collection Periodically\n\n[Timer]\nOnBootSec=30s\nOnUnitActiveSec=15s\nAccuracySec=1s\n\n[Install]\nWantedBy=timers.target\n")
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now vmhost-metrics.timer")
      expect { nx.configure_metrics }.to hop("wait")
    end
  end

  describe "host reboot" do
    it "prep_reboot transitions to reboot" do
      vm1 = create_test_vm(memory_gib: 1)
      vm2 = create_test_vm(memory_gib: 2)
      expect(nx).to receive(:get_boot_id).and_return("xyz")
      expect(nx).to receive(:decr_reboot)
      expect { nx.prep_reboot }.to hop("reboot")
      expect(vm_host.reload.last_boot_id).to eq("xyz")
      expect(vm1.reload.display_state).to eq("rebooting")
      expect(vm2.reload.display_state).to eq("rebooting")
    end

    it "hops to prep_hardware_reset when needed, before checking other semaphores" do
      expect(nx).to receive(:when_hardware_reset_set?).and_yield
      expect { nx.reboot }.to hop("prep_hardware_reset")
    end

    it "reboot naps if host sshable is not available" do
      expect(sshable).to receive(:available?).and_return(false)
      expect { nx.reboot }.to nap(30)
    end

    it "reboot naps if reboot-host returns empty string" do
      vm_host.update(last_boot_id: "xyz")
      expect(sshable).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/reboot-host xyz").and_return ""
      expect { nx.reboot }.to nap(30)
    end

    it "reboot updates last_boot_id and hops to verify_spdk" do
      vm_host.update(last_boot_id: "xyz")
      expect(sshable).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/reboot-host xyz").and_return "pqr\n"
      expect { nx.reboot }.to hop("verify_spdk")
      expect(vm_host.reload.last_boot_id).to eq("pqr")
    end

    it "reboot updates last_boot_id and hops to verify_hugepages when spdk is not instaled" do
      nx_vhost = described_class.new(described_class.assemble("1.2.3.4", spdk_version: nil, vhost_block_backend_version: "someversion"))
      vmh = nx_vhost.vm_host
      vmh.update(last_boot_id: "xyz")
      mock_ssh = create_mock_sshable
      allow(nx_vhost).to receive(:sshable).and_return(mock_ssh)
      expect(mock_ssh).to receive(:available?).and_return(true)
      expect(mock_ssh).to receive(:_cmd).with("sudo host/bin/reboot-host xyz").and_return "pqr\n"
      expect { nx_vhost.reboot }.to hop("verify_hugepages")
      expect(vmh.reload.last_boot_id).to eq("pqr")
    end

    it "verify_spdk hops to verify_hugepages if spdk started" do
      create_test_spdk(version: "v1.0")
      create_test_spdk(version: "v3.0")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-spdk verify v1.0")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-spdk verify v3.0")
      expect { nx.verify_spdk }.to hop("verify_hugepages")
    end

    it "start_slices starts slices" do
      slice1 = create_test_slice(name: "standard1", total_memory_gib: 2)
      slice2 = create_test_slice(name: "standard2", total_memory_gib: 3)
      Strand.create_with_id(slice1.id, prog: "Vm::VmHostSliceNexus", label: "wait")
      Strand.create_with_id(slice2.id, prog: "Vm::VmHostSliceNexus", label: "wait")
      expect { nx.start_slices }.to hop("start_vms")
      expect(Semaphore.where(strand_id: slice1.id, name: "start_after_host_reboot").count).to eq(1)
      expect(Semaphore.where(strand_id: slice2.id, name: "start_after_host_reboot").count).to eq(1)
    end

    it "start_vms starts vms & becomes accepting & hops to wait if unprepared" do
      create_test_vm(memory_gib: 1)
      # vm_host starts as "unprepared" by default
      expect { nx.start_vms }.to hop("configure_metrics")
      expect(vm_host.reload.allocation_state).to eq("accepting")
      # Verify semaphore was created - incr_start_after_host_reboot increments semaphores for all VMs
      expect(Semaphore.where(name: "start_after_host_reboot").count).to be >= 1
    end

    it "start_vms starts vms & becomes accepting & hops to wait if was draining and in graceful reboot" do
      vm_host.update(allocation_state: "draining")
      create_test_vm(memory_gib: 1)
      expect(nx).to receive(:when_graceful_reboot_set?).and_yield
      expect { nx.start_vms }.to hop("configure_metrics")
      expect(vm_host.reload.allocation_state).to eq("accepting")
    end

    it "start_vms starts vms & raises if not in draining and in graceful reboot" do
      vm_host.update(allocation_state: "accepting")
      create_test_vm(memory_gib: 1)
      expect(nx).to receive(:when_graceful_reboot_set?).and_yield
      expect { nx.start_vms }.to raise_error(RuntimeError)
    end

    it "start_vms starts vms & hops to configure_metrics if accepting" do
      vm_host.update(allocation_state: "accepting")
      create_test_vm(memory_gib: 1)
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "start_vms starts vms & hops to wait if draining" do
      vm_host.update(allocation_state: "draining")
      create_test_vm(memory_gib: 1)
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "can get boot id" do
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("xyz\n")
      expect(nx.get_boot_id).to eq("xyz")
    end
  end

  describe "host hardware reset" do
    it "prep_hardware_reset transitions to hardware_reset" do
      vm1 = create_test_vm(memory_gib: 1)
      expect(nx).to receive(:decr_hardware_reset)
      expect { nx.prep_hardware_reset }.to hop("hardware_reset")
      expect(vm1.reload.display_state).to eq("rebooting")
    end

    it "hardware_reset transitions to reboot if is in draining state" do
      vm_host.update(allocation_state: "draining")
      # hardware_reset calls Hosting::Apis - stub at API level
      expect(Hosting::Apis).to receive(:hardware_reset_server)
      expect { nx.hardware_reset }.to hop("reboot")
    end

    it "hardware_reset transitions to reboot if is not in draining state but has no vms" do
      vm_host.update(allocation_state: "accepting")
      # hardware_reset calls Hosting::Apis - stub at API level
      expect(Hosting::Apis).to receive(:hardware_reset_server)
      expect { nx.hardware_reset }.to hop("reboot")
    end

    it "hardware_reset fails if has vms and is not in draining state" do
      vm_host.update(allocation_state: "accepting")
      create_test_vm(memory_gib: 1)
      expect { nx.hardware_reset }.to raise_error RuntimeError, "Host has VMs and is not in draining state"
    end
  end

  describe "#verify_hugepages" do
    it "fails if hugepagesize!=1G" do
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 2048 kB\n")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't set hugepage size to 1G"
    end

    it "fails if total hugepages couldn't be extracted" do
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 1048576 kB\n")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't extract total hugepage count"
    end

    it "fails if free hugepages couldn't be extracted" do
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't extract free hugepage count"
    end

    it "fails if not enough hugepages for VMs" do
      # Create real VMs that require more hugepages than available
      # Total: 5, Spdk: 4 (from fixture), Free: 2 => available for VMs: 5-4=1
      # But VMs need 3 (1+2) which exceeds available 1
      create_test_spdk(cpu_count: 4, hugepages: 4)
      create_test_vm(memory_gib: 1)
      create_test_vm(memory_gib: 2)
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5\nHugePages_Free: 2")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Not enough hugepages for VMs"
    end

    it "fails if used hugepages exceed spdk hugepages" do
      # No spdk installations (sum=0), so used hugepages (10-5=5) exceeds spdk hugepages (0)
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 5")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Used hugepages exceed SPDK hugepages"
    end

    it "calculates used memory for slices and hops" do
      # Setup: spdk hugepages = 4, slice memory = 5 (2+3)
      # Total=10, Free=8 => used=2 <= spdk_hugepages(4) OK
      # available = 10-4=6 >= slice_mem(5) OK
      # Result: used = spdk(4) + slice_mem(5) = 9
      create_test_spdk(cpu_count: 4, hugepages: 4)
      create_test_slice(name: "standard1", total_memory_gib: 2)
      create_test_slice(name: "standard2", total_memory_gib: 3)
      vm_host.update(accepts_slices: true)
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 8")
      expect { nx.verify_hugepages }.to hop("start_slices")
      expect(vm_host.reload.total_hugepages_1g).to eq(10)
      expect(vm_host.reload.used_hugepages_1g).to eq(9)
    end

    it "updates vm_host with hugepage stats and hops" do
      # Setup: spdk hugepages = 4, vm memory = 3 (1+2)
      # Total=10, Free=8 => used=2 <= spdk_hugepages(4) OK
      # available = 10-4=6 >= vm_mem(3) OK
      # Result: used = spdk(4) + vm_mem(3) = 7
      create_test_spdk(cpu_count: 4, hugepages: 4)
      create_test_vm(memory_gib: 1)
      create_test_vm(memory_gib: 2)
      # accepts_slices is false by default
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 8")
      expect { nx.verify_hugepages }.to hop("start_slices")
      expect(vm_host.reload.total_hugepages_1g).to eq(10)
      expect(vm_host.reload.used_hugepages_1g).to eq(7)
    end
  end

  describe "#available?" do
    it "returns the available status when disks are healthy" do
      expect(sshable).to receive(:connect).and_return(nil)
      # Stub on nx.vm_host since let(:vm_host) may not be the same object
      allow(nx).to receive(:vm_host).and_return(vm_host)
      expect(vm_host).to receive(:check_last_boot_id)
      expect(vm_host).to receive(:perform_health_checks).and_return(true)
      expect(nx.available?).to be true
    end

    it "returns the available status when disks are not healthy" do
      expect(sshable).to receive(:connect).and_return(nil)
      allow(nx).to receive(:vm_host).and_return(vm_host)
      expect(vm_host).to receive(:check_last_boot_id)
      allow(vm_host).to receive(:perform_health_checks).and_return(false)
      expect(nx.available?).to be false
    end

    it "returns an error trying to connect to VmHost" do
      expect(sshable).to receive(:connect).and_raise Sshable::SshError.new("ssh failed", "", "", nil, nil)
      expect(nx.available?).to be false
    end
  end
end
