# frozen_string_literal: true

class Prog::Vm::HostNexus < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(sshable_hostname, location_id: Location::HETZNER_FSN1_ID, family: "standard", net6: nil, ndp_needed: false, provider_name: nil, server_identifier: nil, spdk_version: Config.spdk_version, default_boot_images: [])
    DB.transaction do
      unless Location[location_id]
        raise "No existing Location"
      end

      id = VmHost.generate_uuid
      Sshable.create_with_id(id, host: sshable_hostname)
      vmh = VmHost.create_with_id(id, location_id:, family:, net6:, ndp_needed:)

      if provider_name == HostProvider::HETZNER_PROVIDER_NAME || provider_name == HostProvider::LEASEWEB_PROVIDER_NAME
        HostProvider.create do |hp|
          hp.id = id
          hp.provider_name = provider_name
          hp.server_identifier = server_identifier
        end
      end

      if provider_name == HostProvider::HETZNER_PROVIDER_NAME
        vmh.create_addresses
        vmh.set_data_center
        # Avoid overriding custom server names for development hosts.
        vmh.set_server_name unless Config.development?
      else
        Address.create_with_id(id, cidr: sshable_hostname, routed_to_host_id: id)
        AssignedHostAddress.create(ip: sshable_hostname, address_id: id, host_id: id)
      end

      Strand.create_with_id(id,
        prog: "Vm::HostNexus",
        label: "start",
        stack: [{"spdk_version" => spdk_version, "default_boot_images" => default_boot_images}])
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    hop_setup_ssh_keys
  end

  label def setup_ssh_keys
    # Generate a new SSH key if one is not set.
    sshable.update(raw_private_key_1: SshKey.generate.keypair) unless sshable.raw_private_key_1

    if Config.hetzner_ssh_private_key
      root_key = Net::SSH::Authentication::ED25519::PrivKey.read(Config.hetzner_ssh_private_key, Config.hetzner_ssh_private_key_passphrase).sign_key
      root_ssh_key = SshKey.from_binary(root_key.keypair)

      public_keys = sshable.keys.first.public_key
      public_keys += "\n#{Config.operator_ssh_public_keys}" if Config.operator_ssh_public_keys

      Util.rootish_ssh(sshable.host, "root", root_ssh_key.private_key, "echo '#{public_keys}' > ~/.ssh/authorized_keys")
    end

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline("download_boot_images", 10 * 60)
    hop_prep if retval&.dig("msg") == "rhizome user bootstrapped and source installed"

    push Prog::BootstrapRhizome, {"target_folder" => "host"}
  end

  label def prep
    bud Prog::Vm::PrepHost
    bud Prog::LearnNetwork unless vm_host.net6
    bud Prog::LearnMemory
    bud Prog::LearnOs
    bud Prog::LearnCpu
    bud Prog::LearnStorage
    bud Prog::LearnPci
    bud Prog::InstallDnsmasq
    bud Prog::SetupSysstat
    bud Prog::SetupNftables
    bud Prog::SetupNodeExporter
    hop_wait_prep
  end

  def os_supports_slices?(os_version)
    os_version == "ubuntu-24.04"
  end

  label def wait_prep
    reaper = lambda do |st|
      case st.prog
      when "LearnOs"
        os_version = st.exitval.fetch("os_version")
        vm_host.update(os_version: os_version, accepts_slices: os_supports_slices?(os_version))
      when "LearnMemory"
        mem_gib = st.exitval.fetch("mem_gib")
        vm_host.update(total_mem_gib: mem_gib)
      when "LearnCpu"
        arch = st.exitval.fetch("arch")
        total_cores = st.exitval.fetch("total_cores")
        total_cpus = st.exitval.fetch("total_cpus")
        kwargs = {
          arch: arch,
          total_sockets: st.exitval.fetch("total_sockets"),
          total_dies: st.exitval.fetch("total_dies"),
          total_cores: total_cores,
          total_cpus: total_cpus
        }
        vm_host.update(**kwargs)
        (0..total_cpus - 1).each do |cpu|
          VmHostCpu.create(
            vm_host_id: vm_host.id,
            cpu_number: cpu,
            spdk: cpu < vm_host.spdk_cpu_count
          )
        end
      end
    end

    reap(:setup_hugepages, reaper:)
  end

  label def setup_hugepages
    hop_setup_spdk if retval&.dig("msg") == "hugepages installed"

    push Prog::SetupHugepages
  end

  label def setup_spdk
    if retval&.dig("msg") == "SPDK was setup"
      spdk_installation = vm_host.spdk_installations.first
      spdk_cores = (spdk_installation.cpu_count * vm_host.total_cores) / vm_host.total_cpus
      vm_host.update(used_cores: spdk_cores)

      hop_download_boot_images
    end

    push Prog::Storage::SetupSpdk, {
      "version" => frame["spdk_version"],
      "start_service" => false,
      "allocation_weight" => 100
    }
  end

  label def download_boot_images
    register_deadline("prep_reboot", 4 * 60 * 60)
    frame["default_boot_images"].each { |image_name|
      bud Prog::DownloadBootImage, {
        "image_name" => image_name
      }
    }

    hop_wait_download_boot_images
  end

  label def wait_download_boot_images
    reap(:prep_reboot)
  end

  label def prep_reboot
    register_deadline("wait", 15 * 60)
    boot_id = get_boot_id
    vm_host.update(last_boot_id: boot_id)

    vm_host.vms.each { |vm|
      vm.update(display_state: "rebooting")
    }

    decr_reboot

    hop_reboot
  end

  label def reboot
    nap 30 unless sshable.available?

    q_last_boot_id = vm_host.last_boot_id.shellescape
    new_boot_id = sshable.cmd("sudo host/bin/reboot-host #{q_last_boot_id}").strip

    # If we didn't get a valid new boot id, nap. This can happen if reboot-host
    # issues a reboot and returns without closing the ssh connection.
    nap 30 if new_boot_id.length == 0

    vm_host.update(last_boot_id: new_boot_id)
    hop_verify_spdk
  end

  label def prep_hardware_reset
    register_deadline("wait", 20 * 60)
    vm_host.vms_dataset.update(display_state: "rebooting")
    decr_hardware_reset
    hop_hardware_reset
  end

  # Cuts power to a Server and starts it again. This forcefully stops it
  # without giving the Server operating system time to gracefully stop. This
  # may lead to data loss, it’s equivalent to pulling the power cord and
  # plugging it in again. Reset should only be used when reboot does not work.
  label def hardware_reset
    unless vm_host.allocation_state == "draining" || vm_host.vms_dataset.empty?
      fail "Host has VMs and is not in draining state"
    end

    vm_host.hardware_reset

    # Attempt to hop to reboot immediately after sending the hardware reset
    # signal.
    # The reboot may:
    # 1. Fail, if the host is unreachable, which is a typical reason for a
    #    hardware reset.
    # 2. Succeed, if the host is reachable; however, the hardware reset may
    #    interrupt the reboot.
    # Regardless, the hardware reset will proceed, and upon completion, the
    # host will receive a new boot id, allowing the sequence to continue
    # without an additional reboot.
    hop_reboot
  end

  label def verify_spdk
    vm_host.spdk_installations.each { |installation|
      q_version = installation.version.shellescape
      sshable.cmd("sudo host/bin/setup-spdk verify #{q_version}")
    }

    hop_verify_hugepages
  end

  label def verify_hugepages
    host_meminfo = sshable.cmd("cat /proc/meminfo")
    fail "Couldn't set hugepage size to 1G" unless host_meminfo.match?(/^Hugepagesize:\s+1048576 kB$/)

    total_hugepages_match = host_meminfo.match(/^HugePages_Total:\s+(\d+)$/)
    fail "Couldn't extract total hugepage count" unless total_hugepages_match

    free_hugepages_match = host_meminfo.match(/^HugePages_Free:\s+(\d+)$/)
    fail "Couldn't extract free hugepage count" unless free_hugepages_match

    total_hugepages = Integer(total_hugepages_match.captures.first)
    free_hugepages = Integer(free_hugepages_match.captures.first)

    spdk_hugepages = vm_host.spdk_installations.sum { |i| i.hugepages }
    fail "Used hugepages exceed SPDK hugepages" unless total_hugepages - free_hugepages <= spdk_hugepages

    total_vm_mem_gib = vm_host.vms.sum { |vm| vm.memory_gib }
    fail "Not enough hugepages for VMs" unless total_hugepages - spdk_hugepages >= total_vm_mem_gib

    vm_host.update(
      total_hugepages_1g: total_hugepages,
      used_hugepages_1g: spdk_hugepages + total_vm_mem_gib
    )

    hop_start_slices
  end

  label def start_slices
    vm_host.slices.each { |slice|
      slice.incr_start_after_host_reboot
    }

    hop_start_vms
  end

  label def start_vms
    vm_host.vms.each { |vm|
      vm.incr_start_after_host_reboot
    }

    when_graceful_reboot_set? do
      fail "BUG: VmHost not in draining state" unless vm_host.allocation_state == "draining"
      vm_host.update(allocation_state: "accepting")
      decr_graceful_reboot
    end

    vm_host.update(allocation_state: "accepting") if vm_host.allocation_state == "unprepared"

    hop_configure_metrics
  end

  label def prep_graceful_reboot
    case vm_host.allocation_state
    when "accepting"
      vm_host.update(allocation_state: "draining")
    when "draining"
      # nothing
    else
      fail "BUG: VmHost not in accepting or draining state"
    end

    if vm_host.vms_dataset.empty?
      hop_prep_reboot
    end

    nap 30
  end

  label def configure_metrics
    metrics_dir = vm_host.metrics_config[:metrics_dir]
    sshable.cmd("mkdir -p #{metrics_dir}")
    sshable.cmd("tee #{metrics_dir}/config.json > /dev/null", stdin: vm_host.metrics_config.to_json)

    metrics_service = <<SERVICE
[Unit]
Description=VmHost Metrics Collection
After=network-online.target

[Service]
Type=oneshot
User=rhizome
ExecStart=/home/rhizome/common/bin/metrics-collector #{metrics_dir}
StandardOutput=journal
StandardError=journal
SERVICE
    sshable.cmd("sudo tee /etc/systemd/system/vmhost-metrics.service > /dev/null", stdin: metrics_service)

    metrics_interval = vm_host.metrics_config[:interval] || "15s"

    metrics_timer = <<TIMER
[Unit]
Description=Run VmHost Metrics Collection Periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=#{metrics_interval}
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
    sshable.cmd("sudo tee /etc/systemd/system/vmhost-metrics.timer > /dev/null", stdin: metrics_timer)

    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable --now vmhost-metrics.timer")

    hop_wait
  end

  label def wait
    when_graceful_reboot_set? do
      hop_prep_graceful_reboot
    end

    when_reboot_set? do
      hop_prep_reboot
    end

    when_hardware_reset_set? do
      hop_prep_hardware_reset
    end

    when_checkup_set? do
      hop_unavailable if !available?
      decr_checkup
    end

    when_configure_metrics_set? do
      decr_configure_metrics
      hop_configure_metrics
    end

    nap 6 * 60 * 60
  end

  label def unavailable
    if available?
      decr_checkup
      hop_wait
    end

    register_deadline("wait", 45)
    nap 30
  end

  label def destroy
    decr_destroy

    unless vm_host.allocation_state == "draining"
      vm_host.update(allocation_state: "draining")
      nap 5
    end

    unless vm_host.vms.empty?
      Clog.emit("Cannot destroy the vm host with active virtual machines, first clean them up") { vm_host }
      nap 15
    end

    vm_host.destroy
    sshable.destroy

    pop "vm host deleted"
  end

  def get_boot_id
    sshable.cmd("cat /proc/sys/kernel/random/boot_id").strip
  end

  def available?
    vm_host.perform_health_checks(sshable.connect)
  rescue
    false
  end
end
