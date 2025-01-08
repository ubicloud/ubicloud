# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::HetznerServer < Prog::Test::Base
  semaphore :destroy

  def self.assemble(vm_host_id: nil)
    frame = if vm_host_id
      vm_host = VmHost[vm_host_id]
      {
        vm_host_id: vm_host.id, server_id: vm_host.hetzner_host.server_identifier,
        hostname: vm_host.sshable.host, setup_host: false
      }
    else
      {
        server_id: Config.ci_hetzner_sacrificial_server_id, setup_host: true
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
      provider: "hetzner",
      hetzner_server_identifier: frame["server_id"],
      default_boot_images: Option::BootImages.map { _1.name }
    ).subject
    update_stack({"vm_host_id" => vm_host.id})

    hop_wait_setup_host
  end

  label def wait_setup_host
    nap 15 unless vm_host && vm_host.strand.label == "wait"

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

    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    nap 15
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
      HetznerHost.new(server_identifier: frame["server_id"])
    )
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end
end
