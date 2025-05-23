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

  let(:vms) { [instance_double(Vm, memory_gib: 1), instance_double(Vm, memory_gib: 2)] }
  let(:spdk_installations) { [instance_double(SpdkInstallation, cpu_count: 4, hugepages: 4)] }
  let(:vm_host_slices) { [instance_double(VmHostSlice, name: "standard1"), instance_double(VmHostSlice, name: "standard2")] }
  let(:vm_host) { instance_double(VmHost, spdk_installations: spdk_installations, vms: vms, slices: vm_host_slices, id: "1d422893-2955-4c2c-b41c-f2ec70bcd60d", spdk_cpu_count: 2) }
  let(:sshable) { instance_double(Sshable, raw_private_key_1: "bogus") }

  before do
    allow(nx).to receive_messages(vm_host: vm_host, sshable: sshable)
    allow(sshable).to receive(:start_fresh_session).and_return(instance_double(Net::SSH::Connection::Session))
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
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
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
      expect(Util).not_to receive(:rootish_ssh)

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
      expect(Util).to receive(:rootish_ssh).with("127.0.0.1", "root", anything, "echo '#{test_public_keys}' > ~/.ssh/authorized_keys")

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
      expect(Util).to receive(:rootish_ssh).with("127.0.0.1", "root", anything, "echo '#{test_public_keys}' > ~/.ssh/authorized_keys")

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
      expect(vm_host).to receive(:net6).and_return(NetAddr.parse_net("2a01:4f9:2b:35a::/64"))
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
      expect(vm_host).to receive(:net6).and_return(nil)
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
      expect(nx).to receive(:leaf?).and_return(true)
      expect(vm_host).to receive(:update).with(total_mem_gib: 1)
      expect(vm_host).to receive(:update).with(os_version: "ubuntu-22.04", accepts_slices: false)
      expect(vm_host).to receive(:update).with(arch: "arm64", total_cores: 4, total_cpus: 5, total_dies: 3, total_sockets: 2)
      expect(nx).to receive(:reap).and_return([
        instance_double(Strand, prog: "LearnMemory", exitval: {"mem_gib" => 1}),
        instance_double(Strand, prog: "LearnOs", exitval: {"os_version" => "ubuntu-22.04"}),
        instance_double(Strand, prog: "LearnCpu", exitval: {"arch" => "arm64", "total_sockets" => 2, "total_dies" => 3, "total_cores" => 4, "total_cpus" => 5}),
        instance_double(Strand, prog: "ArbitraryOtherProg")
      ])

      (0..4).each do |i|
        expect(VmHostCpu).to receive(:create).with(vm_host_id: vm_host.id, cpu_number: i, spdk: i < 2)
      end

      expect { nx.wait_prep }.to hop("setup_hugepages")
    end

    it "crashes if an expected field is not set for LearnMemory" do
      expect(nx).to receive(:reap).and_return([instance_double(Strand, prog: "LearnMemory", exitval: {})])
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"mem_gib\""
    end

    it "crashes if an expected field is not set for LearnCpu" do
      expect(nx).to receive(:reap).and_return([instance_double(Strand, prog: "LearnCpu", exitval: {})])
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"arch\""
    end

    it "donates to children if they are not exited yet" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_prep }.to nap(1)
    end
  end

  describe "#setup_hugepages" do
    it "pushes the hugepage program" do
      expect { nx.setup_hugepages }.to hop("start", "SetupHugepages")
    end

    it "hops once SetupHugepages has returned" do
      nx.strand.retval = {"msg" => "hugepages installed"}
      expect { nx.setup_hugepages }.to hop("setup_spdk")
    end
  end

  describe "#setup_spdk" do
    it "pushes the spdk program" do
      expect(nx).to receive(:push).with(Prog::Storage::SetupSpdk,
        {
          "version" => Config.spdk_version,
          "start_service" => false,
          "allocation_weight" => 100
        }).and_call_original
      expect { nx.setup_spdk }.to hop("start", "Storage::SetupSpdk")
    end

    it "hops once SetupSpdk has returned" do
      nx.strand.retval = {"msg" => "SPDK was setup"}
      vmh = instance_double(VmHost)
      spdk_installation = SpdkInstallation.new(cpu_count: 4)
      allow(vmh).to receive_messages(
        spdk_installations: [spdk_installation],
        total_cores: 48,
        total_cpus: 96
      )
      allow(nx).to receive(:vm_host).and_return(vmh)
      expect(vmh).to receive(:update).with({used_cores: 2})
      expect { nx.setup_spdk }.to hop("download_boot_images")
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
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_download_boot_images }.to hop("prep_reboot")
    end

    it "donates its time if child strands are still running" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_download_boot_images }.to nap(1)
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
    it "registers an immediate deadline if host is unavailable" do
      expect(nx).to receive(:register_deadline).with("wait", 0)
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
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect(vm_host).to receive(:update).with(allocation_state: "draining")
      expect { nx.destroy }.to nap(5)
    end

    it "waits draining" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(Clog).to receive(:emit).with("Cannot destroy the vm host with active virtual machines, first clean them up").and_call_original
      expect { nx.destroy }.to nap(15)
    end

    it "deletes and exists" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(vm_host).to receive(:vms).and_return([])
      expect(vm_host).to receive(:destroy)
      expect(sshable).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "vm host deleted"})
    end
  end

  describe "host graceful reboot" do
    it "prep_graceful_reboot sets allocation_state to draining if it is in accepting" do
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect(vm_host).to receive(:update).with(allocation_state: "draining")
      expect(vm_host).to receive(:vms_dataset).and_return([true])
      expect { nx.prep_graceful_reboot }.to nap(30)
    end

    it "prep_graceful_reboot does not change allocation_state if it is already draining" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(vm_host).not_to receive(:update)
      expect(vm_host).to receive(:vms_dataset).and_return([true])
      expect { nx.prep_graceful_reboot }.to nap(30)
    end

    it "prep_graceful_reboot fails if not in accepting or draining state" do
      expect(vm_host).to receive(:allocation_state).and_return("unprepared")
      expect(vm_host).not_to receive(:update)
      expect(vm_host).not_to receive(:vms_dataset)
      expect { nx.prep_graceful_reboot }.to raise_error(RuntimeError)
    end

    it "prep_graceful_reboot transitions to prep_reboot if there are no VMs" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(vm_host).to receive(:vms_dataset).and_return([])
      expect { nx.prep_graceful_reboot }.to hop("prep_reboot")
    end

    it "prep_graceful_reboot transitions to nap if there are VMs" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(vm_host).to receive(:vms_dataset).and_return([true])
      expect { nx.prep_graceful_reboot }.to nap(30)
    end
  end

  describe "configure metrics" do
    it "configures the metrics and hops to wait" do
      metrics_config = {
        metrics_dir: "/home/rhizome/host/metrics"
      }
      allow(vm_host).to receive(:metrics_config).and_return(metrics_config)
      expect(sshable).to receive(:cmd).with("mkdir -p /home/rhizome/host/metrics")
      expect(sshable).to receive(:cmd).with("tee /home/rhizome/host/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(sshable).to receive(:cmd).with("sudo tee /etc/systemd/system/vmhost-metrics.service > /dev/null", stdin: "[Unit]\nDescription=VmHost Metrics Collection\nAfter=network-online.target\n\n[Service]\nType=oneshot\nUser=rhizome\nExecStart=/home/rhizome/common/bin/metrics-collector /home/rhizome/host/metrics\nStandardOutput=journal\nStandardError=journal\n")
      expect(sshable).to receive(:cmd).with("sudo tee /etc/systemd/system/vmhost-metrics.timer > /dev/null", stdin: "[Unit]\nDescription=Run VmHost Metrics Collection Periodically\n\n[Timer]\nOnBootSec=30s\nOnUnitActiveSec=15s\nAccuracySec=1s\n\n[Install]\nWantedBy=timers.target\n")
      expect(sshable).to receive(:cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:cmd).with("sudo systemctl enable --now vmhost-metrics.timer")
      expect { nx.configure_metrics }.to hop("wait")
    end
  end

  describe "host reboot" do
    it "prep_reboot transitions to reboot" do
      expect(nx).to receive(:get_boot_id).and_return("xyz")
      expect(vm_host).to receive(:update).with(last_boot_id: "xyz")
      expect(vms).to all receive(:update).with(display_state: "rebooting")
      expect(nx).to receive(:decr_reboot)
      expect { nx.prep_reboot }.to hop("reboot")
    end

    it "reboot naps if host sshable is not available" do
      expect(sshable).to receive(:available?).and_return(false)

      expect { nx.reboot }.to nap(30)
    end

    it "reboot naps if reboot-host returns empty string" do
      expect(sshable).to receive(:available?).and_return(true)
      expect(vm_host).to receive(:last_boot_id).and_return("xyz")
      expect(sshable).to receive(:cmd).with("sudo host/bin/reboot-host xyz").and_return ""

      expect { nx.reboot }.to nap(30)
    end

    it "reboot updates last_boot_id and hops to verify_spdk" do
      expect(sshable).to receive(:available?).and_return(true)
      expect(vm_host).to receive(:last_boot_id).and_return("xyz")
      expect(sshable).to receive(:cmd).with("sudo host/bin/reboot-host xyz").and_return "pqr\n"
      expect(vm_host).to receive(:update).with(last_boot_id: "pqr")

      expect { nx.reboot }.to hop("verify_spdk")
    end

    it "verify_spdk hops to verify_hugepages if spdk started" do
      expect(vm_host).to receive(:spdk_installations).and_return([
        SpdkInstallation.new(version: "v1.0"),
        SpdkInstallation.new(version: "v3.0")
      ])
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk verify v1.0")
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk verify v3.0")
      expect { nx.verify_spdk }.to hop("verify_hugepages")
    end

    it "start_slices starts slices" do
      slice1 = instance_double(VmHostSlice)
      slice2 = instance_double(VmHostSlice)
      expect(vm_host).to receive(:slices).and_return([slice1, slice2])
      expect(slice1).to receive(:incr_start_after_host_reboot)
      expect(slice2).to receive(:incr_start_after_host_reboot)
      expect { nx.start_slices }.to hop("start_vms")
    end

    it "start_vms starts vms & becomes accepting & hops to wait if unprepared" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(vm_host).to receive(:allocation_state).and_return("unprepared")
      expect(vm_host).to receive(:update).with(allocation_state: "accepting")
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "start_vms starts vms & becomes accepting & hops to wait if was draining an in graceful reboot" do
      expect(vm_host).to receive(:allocation_state).twice.and_return("draining")
      expect(nx).to receive(:when_graceful_reboot_set?).and_yield
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(vm_host).to receive(:update).with(allocation_state: "accepting")
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "start_vms starts vms & raises if not in draining and in graceful reboot" do
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect(nx).to receive(:when_graceful_reboot_set?).and_yield
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect { nx.start_vms }.to raise_error(RuntimeError)
    end

    it "start_vms starts vms & hops to configure_metrics if accepting" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "start_vms starts vms & hops to wait if draining" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect { nx.start_vms }.to hop("configure_metrics")
    end

    it "can get boot id" do
      expect(sshable).to receive(:cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("xyz\n")
      expect(nx.get_boot_id).to eq("xyz")
    end
  end

  describe "host hardware reset" do
    it "prep_hardware_reset transitions to hardware_reset" do
      vms_dataset = instance_double(Vm.dataset.class)
      expect(vm_host).to receive(:vms_dataset).and_return(vms_dataset)
      expect(vms_dataset).to receive(:update).with(display_state: "rebooting")
      expect(nx).to receive(:decr_hardware_reset)
      expect { nx.prep_hardware_reset }.to hop("hardware_reset")
    end

    it "hardware_reset transitions to reboot if is in draining state" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(vm_host).to receive(:hardware_reset)
      expect { nx.hardware_reset }.to hop("reboot")
    end

    it "hardware_reset transitions to reboot if is not in draining state but has no vms" do
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      vms_dataset = instance_double(Vm.dataset.class)
      expect(vm_host).to receive(:vms_dataset).and_return(vms_dataset)
      expect(vms_dataset).to receive(:empty?).and_return(true)
      expect(vm_host).to receive(:hardware_reset)
      expect { nx.hardware_reset }.to hop("reboot")
    end

    it "hardware_reset fails if has vms and is not in draining state" do
      vms_dataset = instance_double(Vm.dataset.class)
      expect(vm_host).to receive(:vms_dataset).and_return(vms_dataset)
      expect(vms_dataset).to receive(:empty?).and_return(false)
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect { nx.hardware_reset }.to raise_error RuntimeError, "Host has VMs and is not in draining state"
    end
  end

  describe "#verify_hugepages" do
    it "fails if hugepagesize!=1G" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 2048 kB\n")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't set hugepage size to 1G"
    end

    it "fails if total hugepages couldn't be extracted" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 1048576 kB\n")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't extract total hugepage count"
    end

    it "fails if free hugepages couldn't be extracted" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't extract free hugepage count"
    end

    it "fails if not enough hugepages for VMs" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5\nHugePages_Free: 2")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Not enough hugepages for VMs"
    end

    it "fails if used hugepages exceed spdk hugepages" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 5")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Used hugepages exceed SPDK hugepages"
    end

    it "updates vm_host with hugepage stats and hops" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 10\nHugePages_Free: 8")
      expect(vm_host).to receive(:update)
        .with(total_hugepages_1g: 10, used_hugepages_1g: 7)
      expect { nx.verify_hugepages }.to hop("start_slices")
    end
  end

  describe "#available?" do
    it "returns the available status when disks are healthy" do
      expect(sshable).to receive(:connect).and_return(nil)
      expect(vm_host).to receive(:perform_health_checks).and_return(true)
      expect(nx.available?).to be true
    end

    it "returns the available status when disks are not healthy" do
      expect(sshable).to receive(:connect).and_return(nil)
      allow(vm_host).to receive(:perform_health_checks).and_return(false)
      expect(nx.available?).to be false
    end

    it "returns an error trying to connect to VmHost" do
      expect(sshable).to receive(:connect).and_raise Sshable::SshError.new("ssh failed", "", "", nil, nil)
      expect(nx.available?).to be false
    end
  end
end
