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
        server_id: Config.ci_hetzner_sacrificial_server_id, setup_host: true,
        default_boot_images:, provider_name: HostProvider::HETZNER_PROVIDER_NAME
      }
    end

    if frame[:server_id].nil? || frame[:server_id].empty?
      fail "CI_HETZNER_SACRIFICIAL_SERVER_ID must be a nonempty string"
    end

    Strand.create_with_id(
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
      default_boot_images: frame["default_boot_images"]
    ).subject
    update_stack({"vm_host_id" => vm_host.id})

    hop_wait_setup_host
  end

  label def wait_setup_host
    unless vm_host.strand.label == "wait"
      Clog.emit(vm_host.sshable.cmd("ls -lah /var/storage/images").strip.tr("\n", "\t")) if vm_host.strand.label == "wait_download_boot_images"
      nap 15
    end

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
    vm_host.sshable.cmd("sudo RUN_E2E_TESTS=1 SPDK_TESTS_TMP_DIR=#{tmp_dir} bundle exec rspec host/e2e")
    vm_host.sshable.cmd("sudo rm -rf #{tmp_dir}")

    hop_install_vhost_backend
  end

  label def install_vhost_backend
    hop_wait if retval&.dig("msg") == "VhostBlockBackend was setup"
    push Prog::Storage::SetupVhostBlockBackend, {
      "subject_id" => vm_host.id,
      "version" => Config.vhost_block_backend_version,
      "allocation_weight" => 100
    }
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
    hop_verify_spdk_artifacts_purged
  end

  label def verify_spdk_artifacts_purged
    sshable = vm_host.sshable

    spdk_version = vm_host.spdk_installations.first.version
    rpc_py = "/opt/spdk-#{spdk_version}/scripts/rpc.py"
    rpc_sock = "/home/spdk/spdk-#{spdk_version}.sock"

    bdevs = JSON.parse(sshable.cmd("sudo #{rpc_py} -s #{rpc_sock} bdev_get_bdevs")).map { it["name"] }
    fail_test "SPDK bdevs not empty: #{bdevs}" unless bdevs.empty?

    vhost_controllers = JSON.parse(sshable.cmd("sudo #{rpc_py} -s #{rpc_sock} vhost_get_controllers")).map { it["ctrlr"] }
    fail_test "SPDK vhost controllers not empty: #{vhost_controllers}" unless vhost_controllers.empty?

    hop_destroy
  end

  label def destroy
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
