# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::HetznerServer < Prog::Test::Base
  semaphore :verify_cleanup_and_destroy, :disallow_slices

  def self.assemble(vm_host_id: nil, default_boot_images: [])
    frame = if vm_host_id
      vm_host = VmHost[vm_host_id]
      {
        vm_host_id: vm_host.id, server_id: vm_host.provider.server_identifier,
        hostname: vm_host.sshable.host, setup_host: false,
        default_boot_images:, provider_name: vm_host.provider_name
      }
    else
      {
        server_id: Config.e2e_hetzner_server_id, setup_host: true,
        default_boot_images:, provider_name: HostProvider::HETZNER_PROVIDER_NAME
      }
    end

    if frame[:server_id].nil? || frame[:server_id].empty?
      fail "E2E_HETZNER_SERVER_ID must be a nonempty string"
    end

    Strand.create(
      prog: "Test::HetznerServer",
      label: "start",
      stack: [frame]
    )
  end

  label def start
    hop_wait_setup_host unless frame["setup_host"]
    hop_fetch_hostname
  end

  label def fetch_hostname
    update_stack({"hostname" => hetzner_api.get_main_ip4})

    hop_reimage
  end

  label def reimage
    hetzner_api.reimage(
      frame["server_id"],
      dist: "Ubuntu 24.04 LTS base"
    )

    hop_wait_reimage
  end

  label def wait_reimage
    begin
      Util.rootish_ssh(frame["hostname"], "root", [Config.hetzner_ssh_private_key], "echo 1")
    rescue
      nap 15
    end

    hop_setup_host
  end

  label def setup_host
    vm_host = Prog::Vm::HostNexus.assemble(
      frame["hostname"],
      provider_name: HostProvider::HETZNER_PROVIDER_NAME,
      server_identifier: frame["server_id"],
      default_boot_images: frame["default_boot_images"],
      spdk_version: nil,
      vhost_block_backend_version: Config.vhost_block_backend_version
    ).subject
    update_stack({"vm_host_id" => vm_host.id})

    hop_wait_setup_host
  end

  label def wait_setup_host
    unless vm_host.strand.label == "wait"
      Clog.emit(vm_host.sshable.cmd("ls -lah /var/storage/images").strip.tr("\n", "\t")) if vm_host.strand.label == "wait_download_boot_images"
      nap 15
    end
    update_stack({"available_storage_gib" => vm_host.available_storage_gib})

    hop_install_integration_specs
  end

  label def install_integration_specs
    if retval&.dig("msg") == "installed rhizome"
      verify_specs_installation(installed: true)

      hop_run_integration_specs
    end

    # We shouldn't install specs by default when running Prog::Vm::HostNexus.assemble
    verify_specs_installation(installed: false) if frame["setup_host"]

    # install specs
    push Prog::InstallRhizome, {subject_id: vm_host.id, target_folder: "host", install_specs: true}
  end

  def verify_specs_installation(installed: true)
    specs_count = vm_host.sshable.cmd("find /home/rhizome -type f -name '*_spec.rb' -not -path \"/home/rhizome/vendor/*\" | wc -l")
    specs_installed = (specs_count.strip != "0")
    fail_test "verify_specs_installation(installed: #{installed}) failed" unless specs_installed == installed
  end

  label def run_integration_specs
    tmp_dir = "/var/storage/tests"
    vm_host.sshable.cmd("sudo mkdir -p #{tmp_dir}")
    vm_host.sshable.cmd("sudo chmod a+rw #{tmp_dir}")
    vm_host.sshable.cmd("sudo RUN_E2E_TESTS=1 bundle exec rspec host/e2e")
    vm_host.sshable.cmd("sudo rm -rf #{tmp_dir}")

    hop_wait
  end

  label def wait
    when_verify_cleanup_and_destroy_set? do
      hop_verify_cleanup
    end

    when_disallow_slices_set? do
      hop_disallow_slices
    end

    nap 15
  end

  label def disallow_slices
    vm_host.disallow_slices
    Semaphore.where(strand_id: strand.id, name: "disallow_slices").destroy

    hop_wait
  end

  label def verify_cleanup
    # not all tests will wait for cleanup, so we need to wait here until the
    # cleanup is done
    nap 15 unless vm_host.vms.empty?

    hop_verify_vm_dir_purged
  end

  label def verify_vm_dir_purged
    sshable = vm_host.sshable
    vm_dir_content = sshable.cmd("sudo ls -1 /vm").split("\n")
    fail_test "VM directory not empty: #{vm_dir_content}" unless vm_dir_content.empty?
    hop_verify_storage_files_purged
  end

  label def verify_storage_files_purged
    sshable = vm_host.sshable

    vm_disks = sshable.cmd("sudo ls -1 /var/storage").split("\n").reject { ["vhost", "images"].include? it }
    fail_test "VM disks not empty: #{vm_disks}" unless vm_disks.empty?

    vhost_dir_content = sshable.cmd("sudo ls -1 /var/storage/vhost").split("\n")
    fail_test "vhost directory not empty: #{vhost_dir_content}" unless vhost_dir_content.empty?
    hop_verify_resources_reclaimed
  end

  label def verify_resources_reclaimed
    fail_test "used_cores is expected to be zero, actual: #{vm_host.used_cores}" unless vm_host.used_cores.zero?
    fail_test "used_hugepages_1g is expected to be zero, actual: #{vm_host.used_hugepages_1g}" unless vm_host.used_hugepages_1g.zero?
    fail_test "available_storage_gib was not reclaimed as expected: #{frame["available_storage_gib"]}, actual: #{vm_host.available_storage_gib}" unless frame["available_storage_gib"] == vm_host.available_storage_gib

    hop_destroy_vm_host
  end

  label def destroy_vm_host
    # don't destroy the vm_host if we didn't set it up.
    hop_finish unless frame["setup_host"]

    vm_host.incr_destroy

    hop_wait_vm_host_destroyed
  end

  label def wait_vm_host_destroyed
    if vm_host
      Clog.emit("Waiting vm host to be destroyed")
      nap 10
    end

    hop_finish
  end

  label def finish
    pop "HetznerServer tests finished!"
  end

  label def failed
    nap 15
  end

  def hetzner_api
    @hetzner_api ||= Hosting::HetznerApis.new(
      HostProvider.new do |hp|
        hp.server_identifier = frame["server_id"]
        hp.provider_name = HostProvider::HETZNER_PROVIDER_NAME
        hp.id = frame["vm_host_id"]
      end
    )
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end
end
