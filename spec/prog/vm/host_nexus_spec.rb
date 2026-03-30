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

  let(:vm_host) { nx.vm_host }
  let(:sshable) { nx.sshable }

  before do
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

    it "stores vhost_block_backend settings in stack" do
      st = described_class.assemble("127.0.0.1", vhost_block_backend_version: "v0.2.2")
      expect(st.stack.first["vhost_block_backend_version"]).to eq("v0.2.2")

      st = described_class.assemble("1.2.3.4")
      expect(st.stack.first["vhost_block_backend_version"]).to eq(Config.vhost_block_backend_version)
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

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
      expect(sshable.reload.raw_private_key_1).to be_instance_of(String)
      expect(sshable.raw_private_key_1.length).to eq 64
    end

    it "does not generate a keypair if one is already set" do
      expect(Config).to receive(:hetzner_ssh_private_key).and_return(nil)
      keypair = SshKey.generate.keypair
      sshable.update(raw_private_key_1: keypair)
      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
      expect(sshable.reload.raw_private_key_1).to eq(keypair)
    end

    it "skips if private key is not set" do
      expect(Config).to receive(:hetzner_ssh_private_key).and_return(nil)
      expect(Net::SSH).not_to receive(:start)

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
    end

    it "adds a public key if private key is set" do
      root_key = SshKey.generate
      vmhost_key = SshKey.generate
      sshable.update(raw_private_key_1: vmhost_key.keypair)
      test_public_keys = vmhost_key.public_key.to_s

      expect(Config).to receive(:hetzner_ssh_private_key).exactly(2).and_return(root_key.private_key)
      expect(Config).to receive(:operator_ssh_public_keys).and_return(nil)
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
      sshable.update(raw_private_key_1: vmhost_key.keypair)
      test_public_keys = "#{vmhost_key.public_key}\n#{operational_key_1.public_key}\n#{operational_key_2.public_key}"

      expect(Config).to receive(:hetzner_ssh_private_key).exactly(2).and_return(root_key.private_key)
      expect(Config).to receive(:operator_ssh_public_keys).exactly(2).and_return("#{operational_key_1.public_key}\n#{operational_key_2.public_key}")
      session = Net::SSH::Connection::Session.allocate
      expect(Net::SSH).to receive(:start).and_yield(session)
      expect(session).to receive(:_exec!).with("echo #{test_public_keys.gsub(" ", "\\ ").gsub("\n", "'\n'")} > ~/.ssh/authorized_keys").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))

      expect { nx.setup_ssh_keys }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "pushes a bootstrap rhizome process" do
      expect { nx.bootstrap_rhizome }.to raise_error(Prog::Base::Hop) { |hop|
        expect(hop.new_label).to eq("start")
        expect(hop.new_prog).to eq("BootstrapRhizome")
        expect(hop.strand_update_args[:stack].first).to include("target_folder" => "host")
      }
    end

    it "hops once BootstrapRhizome has returned" do
      nx.strand.retval = {"msg" => "rhizome user bootstrapped and source installed"}
      expect { nx.bootstrap_rhizome }.to hop("prep")
    end
  end

  describe "#prep" do
    it "starts a number of sub-programs" do
      vm_host.update(net6: "2a01:4f9:2b:35a::/64")

      expect { nx.prep }.to hop("wait_prep")

      child_progs = Strand.where(parent_id: st.id).select_order_map(:prog)
      expect(child_progs).to eq([
        "InstallDnsmasq",
        "LearnCpu",
        "LearnMemory",
        "LearnOs",
        "LearnPci",
        "LearnStorage",
        "SetupNftables",
        "SetupNodeExporter",
        "SetupSysstat",
        "Vm::PrepHost"
      ])
    end

    it "learns the network from the host if it is not set a-priori" do
      expect { nx.prep }.to hop("wait_prep")

      child_progs = Strand.where(parent_id: st.id).select_map(:prog)
      expect(child_progs).to include("LearnNetwork")
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
      Strand.create(parent_id: st.id, prog: "LearnMemory", label: "start", exitval: {"mem_gib" => 1})
      Strand.create(parent_id: st.id, prog: "LearnOs", label: "start", exitval: {"os_version" => "ubuntu-24.04"})
      Strand.create(parent_id: st.id, prog: "LearnCpu", label: "start", exitval: {"arch" => "arm64", "total_sockets" => 2, "total_dies" => 3, "total_cores" => 4, "total_cpus" => 5})
      Strand.create(parent_id: st.id, prog: "ArbitraryOtherProg", label: "start", exitval: {})

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
      Strand.create(parent_id: st.id, prog: "LearnMemory", label: "start", exitval: {})
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"mem_gib\""
    end

    it "crashes if an expected field is not set for LearnCpu" do
      Strand.create(parent_id: st.id, prog: "LearnCpu", label: "start", exitval: {})
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"arch\""
    end

    it "donates to children if they are not exited yet" do
      Strand.create(parent_id: st.id, prog: "LearnCpu", label: "start", lease: Time.now + 10)
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
    it "pushes the vhost_block_backend program by default" do
      vm_host.update(arch: "x64")
      expect { nx.setup_storage_backend }.to raise_error(Prog::Base::Hop) { |hop|
        expect(hop.new_label).to eq("start")
        expect(hop.new_prog).to eq("Storage::SetupVhostBlockBackend")
        expect(hop.strand_update_args[:stack].first).to include("allocation_weight" => 100)
      }
    end

    it "hops once SetupVhostBlockBackend has returned" do
      nx.strand.retval = {"msg" => "VhostBlockBackend was setup"}
      expect { nx.setup_storage_backend }.to hop("download_boot_images")
    end
  end

  describe "#download_boot_images" do
    it "pushes the download boot image program" do
      refresh_frame(nx, new_values: {"default_boot_images" => ["ubuntu-jammy", "github-ubuntu-2204"]})
      expect { nx.download_boot_images }.to hop("wait_download_boot_images")
      children = Strand.where(parent_id: st.id, prog: "DownloadBootImage").all
      expect(children.map { it.stack.first["image_name"] }.sort).to eq(["github-ubuntu-2204", "ubuntu-jammy"])
    end
  end

  describe "#wait_download_boot_images" do
    it "hops to prep_reboot if all tasks are done" do
      expect { nx.wait_download_boot_images }.to hop("prep_reboot")
    end

    it "donates its time if child strands are still running" do
      Strand.create(parent_id: st.id, prog: "DownloadBootImage", label: "start", lease: Time.now + 10)
      expect { nx.wait_download_boot_images }.to nap(120)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to prep_graceful_reboot when needed" do
      nx.incr_graceful_reboot
      expect { nx.wait }.to hop("prep_graceful_reboot")
    end

    it "hops to prep_reboot when needed" do
      nx.incr_reboot
      expect { nx.wait }.to hop("prep_reboot")
    end

    it "hops to prep_hardware_reset when needed" do
      nx.incr_hardware_reset
      expect { nx.wait }.to hop("prep_hardware_reset")
    end

    it "hops to configure_metrics when needed" do
      nx.incr_configure_metrics
      expect { nx.wait }.to hop("configure_metrics")
    end

    it "hops to unavailable based on the host's available status" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")

      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#unavailable" do
    it "hops to prep_graceful_reboot when needed" do
      nx.incr_graceful_reboot
      expect { nx.unavailable }.to hop("prep_graceful_reboot")
    end

    it "hops to prep_reboot when needed" do
      nx.incr_reboot
      expect { nx.unavailable }.to hop("prep_reboot")
    end

    it "hops to prep_hardware_reset when needed" do
      nx.incr_hardware_reset
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
      create_vm(vm_host_id: vm_host.id)
      expect(Clog).to receive(:emit).with("Cannot destroy the vm host with active virtual machines, first clean them up", vm_host).and_call_original
      expect { nx.destroy }.to nap(15)
    end

    it "deletes and exits" do
      vm_host.update(allocation_state: "draining")
      expect(vm_host).to receive(:destroy)
      expect(sshable).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "vm host deleted"})
    end
  end

  describe "host graceful reboot" do
    it "prep_graceful_reboot sets allocation_state to draining if it is in accepting" do
      vm_host.update(allocation_state: "accepting")
      create_vm(vm_host_id: vm_host.id)
      expect { nx.prep_graceful_reboot }.to nap(30)
      expect(vm_host.reload.allocation_state).to eq("draining")
    end

    it "prep_graceful_reboot does not change allocation_state if it is already draining" do
      vm_host.update(allocation_state: "draining")
      create_vm(vm_host_id: vm_host.id)
      expect { nx.prep_graceful_reboot }.to nap(30)
      expect(vm_host.reload.allocation_state).to eq("draining")
    end

    it "prep_graceful_reboot fails if not in accepting or draining state" do
      vm_host.update(allocation_state: "unprepared")
      expect { nx.prep_graceful_reboot }.to raise_error(RuntimeError)
    end

    it "prep_graceful_reboot transitions to prep_reboot if there are no VMs" do
      vm_host.update(allocation_state: "draining")
      expect { nx.prep_graceful_reboot }.to hop("prep_reboot")
    end

    it "prep_graceful_reboot transitions to nap if there are VMs" do
      vm_host.update(allocation_state: "draining")
      create_vm(vm_host_id: vm_host.id)
      expect { nx.prep_graceful_reboot }.to nap(30)
    end
  end

  describe "configure metrics" do
    it "configures the metrics and hops to wait" do
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/rhizome/host/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/rhizome/host/metrics/config.json > /dev/null", stdin: vm_host.metrics_config.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/vmhost-metrics.service > /dev/null", stdin: "[Unit]\nDescription=VmHost Metrics Collection\nAfter=network-online.target\n\n[Service]\nType=oneshot\nUser=rhizome\nExecStart=/home/rhizome/common/bin/metrics-collector /home/rhizome/host/metrics\nStandardOutput=journal\nStandardError=journal\n")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/vmhost-metrics.timer > /dev/null", stdin: "[Unit]\nDescription=Run VmHost Metrics Collection Periodically\n\n[Timer]\nOnBootSec=30s\nOnUnitActiveSec=15s\nAccuracySec=1s\n\n[Install]\nWantedBy=timers.target\n")
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now vmhost-metrics.timer")
      expect { nx.configure_metrics }.to hop("wait")
    end
  end

  describe "host reboot" do
    it "prep_reboot transitions to reboot" do
      expect(nx).to receive(:get_boot_id).and_return("xyz")
      vm1 = create_vm(vm_host_id: vm_host.id, name: "vm1")
      vm2 = create_vm(vm_host_id: vm_host.id, name: "vm2")
      nx.incr_reboot
      expect(nx.reboot_set?).to be true
      expect { nx.prep_reboot }.to hop("reboot")
      expect(vm_host.reload.last_boot_id).to eq("xyz")
      expect(vm1.reload.display_state).to eq("rebooting")
      expect(vm2.reload.display_state).to eq("rebooting")
      expect(nx.reboot_set?).to be false
    end

    it "hops to prep_hardware_reset when needed, before checking other semaphores" do
      nx.incr_hardware_reset
      expect { nx.reboot }.to hop("prep_hardware_reset")
    end

    it "reboot naps if host sshable is not available" do
      expect(sshable).to receive(:available?).and_return(false)

      expect { nx.reboot }.to nap(30)
    end

    it "reboot naps if reboot-host returns empty string" do
      expect(sshable).to receive(:available?).and_return(true)
      vm_host.update(last_boot_id: "xyz")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/reboot-host xyz").and_return ""

      expect { nx.reboot }.to nap(30)
    end

    it "reboot updates last_boot_id and hops to verify_spdk when spdk is installed" do
      expect(sshable).to receive(:available?).and_return(true)
      vm_host.update(last_boot_id: "xyz")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/reboot-host xyz").and_return "pqr\n"
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 100)

      expect { nx.reboot }.to hop("verify_spdk")
      expect(vm_host.reload.last_boot_id).to eq("pqr")
    end

    it "reboot updates last_boot_id and hops to verify_hugepages when spdk is not installed" do
      expect(sshable).to receive(:available?).and_return(true)
      vm_host.update(last_boot_id: "xyz")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/reboot-host xyz").and_return "pqr\n"

      expect { nx.reboot }.to hop("verify_hugepages")
      expect(vm_host.reload.last_boot_id).to eq("pqr")
    end

    it "verify_spdk hops to verify_hugepages if spdk started" do
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1.0", allocation_weight: 100)
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v3.0", allocation_weight: 100)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-spdk verify v1.0")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-spdk verify v3.0")
      expect { nx.verify_spdk }.to hop("verify_hugepages")
    end

    it "start_slices starts slices" do
      slice1 = create_vm_host_slice(vm_host_id: vm_host.id, name: "standard1")
      slice2 = create_vm_host_slice(vm_host_id: vm_host.id, name: "standard2")
      Strand.create(id: slice1.id, prog: "Vm::VmHostSliceNexus", label: "wait")
      Strand.create(id: slice2.id, prog: "Vm::VmHostSliceNexus", label: "wait")
      expect { nx.start_slices }.to hop("start_vms")
      expect(slice1.start_after_host_reboot_set?).to be true
      expect(slice2.start_after_host_reboot_set?).to be true
    end

    it "start_vms starts vms & becomes accepting & hops to configure_metrics if unprepared" do
      vm_host.update(allocation_state: "unprepared")
      vm = create_vm(vm_host_id: vm_host.id)
      Strand.create(id: vm.id, prog: "Vm::Nexus", label: "wait")
      expect { nx.start_vms }.to hop("configure_metrics")
      expect(vm_host.reload.allocation_state).to eq("accepting")
      expect(vm.start_after_host_reboot_set?).to be true
    end

    it "start_vms starts vms & becomes accepting & hops to configure_metrics if was draining and in graceful reboot" do
      vm_host.update(allocation_state: "draining")
      nx.incr_graceful_reboot
      vm = create_vm(vm_host_id: vm_host.id)
      Strand.create(id: vm.id, prog: "Vm::Nexus", label: "wait")
      expect { nx.start_vms }.to hop("configure_metrics")
      expect(vm_host.reload.allocation_state).to eq("accepting")
    end

    it "start_vms starts vms & raises if not in draining and in graceful reboot" do
      vm_host.update(allocation_state: "accepting")
      nx.incr_graceful_reboot
      vm = create_vm(vm_host_id: vm_host.id)
      Strand.create(id: vm.id, prog: "Vm::Nexus", label: "wait")
      expect { nx.start_vms }.to raise_error(RuntimeError)
    end

    it "start_vms starts vms & hops to configure_metrics if accepting" do
      vm_host.update(allocation_state: "accepting")
      vm = create_vm(vm_host_id: vm_host.id)
      Strand.create(id: vm.id, prog: "Vm::Nexus", label: "wait")
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "start_vms starts vms & hops to configure_metrics if draining" do
      vm_host.update(allocation_state: "draining")
      vm = create_vm(vm_host_id: vm_host.id)
      Strand.create(id: vm.id, prog: "Vm::Nexus", label: "wait")
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "can get boot id" do
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("xyz\n")
      expect(nx.get_boot_id).to eq("xyz")
    end
  end

  describe "host hardware reset" do
    it "prep_hardware_reset transitions to hardware_reset" do
      vm1 = create_vm(vm_host_id: vm_host.id, name: "vm1", display_state: "running")
      vm2 = create_vm(vm_host_id: vm_host.id, name: "vm2", display_state: "running")
      expect { nx.prep_hardware_reset }.to hop("hardware_reset")
      expect(vm1.reload.display_state).to eq("rebooting")
      expect(vm2.reload.display_state).to eq("rebooting")
    end

    it "hardware_reset transitions to reboot if is in draining state" do
      vm_host.update(allocation_state: "draining")
      expect(vm_host).to receive(:hardware_reset)
      expect { nx.hardware_reset }.to hop("reboot")
    end

    it "hardware_reset transitions to reboot if is not in draining state but has no vms" do
      vm_host.update(allocation_state: "accepting")
      expect(vm_host).to receive(:hardware_reset)
      expect { nx.hardware_reset }.to hop("reboot")
    end

    it "hardware_reset fails if has vms and is not in draining state" do
      vm_host.update(allocation_state: "accepting")
      create_vm(vm_host_id: vm_host.id)
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
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5\nHugePages_Free: 2")
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 100, hugepages: 4)
      create_vm(vm_host_id: vm_host.id, name: "vm1", memory_gib: 1)
      create_vm(vm_host_id: vm_host.id, name: "vm2", memory_gib: 2)
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Not enough hugepages for VMs"
    end

    it "fails if used hugepages exceed spdk hugepages" do
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 5")
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 100, hugepages: 4)
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Used hugepages exceed SPDK hugepages"
    end

    it "calculates used memory for slices and hops" do
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 8")
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 100, hugepages: 4)
      vm_host.update(accepts_slices: true)
      create_vm_host_slice(vm_host_id: vm_host.id, name: "standard1", total_memory_gib: 2)
      create_vm_host_slice(vm_host_id: vm_host.id, name: "standard2", total_memory_gib: 3)
      expect { nx.verify_hugepages }.to hop("start_slices")
      expect(vm_host.reload.total_hugepages_1g).to eq(10)
      expect(vm_host.used_hugepages_1g).to eq(9)
    end

    it "updates vm_host with hugepage stats and hops" do
      expect(sshable).to receive(:_cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 8")
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 100, hugepages: 4)
      create_vm(vm_host_id: vm_host.id, name: "vm1", memory_gib: 1)
      create_vm(vm_host_id: vm_host.id, name: "vm2", memory_gib: 2)
      expect { nx.verify_hugepages }.to hop("start_slices")
      expect(vm_host.reload.total_hugepages_1g).to eq(10)
      expect(vm_host.used_hugepages_1g).to eq(7)
    end
  end

  describe "#available?" do
    it "returns the available status when disks are healthy" do
      expect(sshable).to receive(:connect).and_return(nil)
      expect(vm_host).to receive(:check_last_boot_id)
      expect(vm_host).to receive(:perform_health_checks).and_return(true)
      expect(nx.available?).to be true
    end

    it "returns the available status when disks are not healthy" do
      expect(sshable).to receive(:connect).and_return(nil)
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
