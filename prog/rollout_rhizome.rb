# frozen_string_literal: true

class Prog::RolloutRhizome < Prog::Base
  semaphore :pause, :github_runners_work, :destroy

  def self.assemble(vm_project_id: Config.rollouts_project_id)
    vm_host_ds = VmHost
      .order(Sequel.function(:random))
      .where(allocation_state: "accepting")
      .where { total_cores >= used_cores + 4 }

    initial_host_ids = [
      vm_host_ds.where(location_id: Location::HETZNER_FSN1_ID).get(:id),
      vm_host_ds.where(location_id: Location::LEASEWEB_WDC02_ID).get(:id),
    ]
    initial_host_ids.compact!

    initial_github_runner_host_ds = vm_host_ds
      .where(location_id: Location::GITHUB_RUNNERS_ID)
      .limit(2)

    initial_github_runner_host_ids = DB.ignore_duplicate_queries do
      %w[x64 arm64].flat_map do |arch|
        initial_github_runner_host_ds
          .where(arch:)
          .select_map(:id)
      end
    end

    location_ids = [
      Location::HETZNER_FSN1_ID,
      Location::HETZNER_HEL1_ID,
      Location::GITHUB_RUNNERS_ID,
      Location::LEASEWEB_WDC02_ID,
    ]

    remaining_host_ids = VmHost
      .order(:created_at)
      .exclude(id: initial_host_ids + initial_github_runner_host_ids)
      .where(location_id: location_ids)
      .select_map(:id)

    Strand.create(
      prog: "RolloutRhizome",
      label: "start",
      stack: [{
        "vm_project_id" => vm_project_id,
        "initial_host_ids" => initial_host_ids,
        "initial_github_runner_host_ids" => initial_github_runner_host_ids,
        "remaining_host_ids" => remaining_host_ids,
        "completed" => [],
      }],
    )
  end

  def before_run
    when_pause_set? do
      nap 60 * 60
    end
    super
  end

  label def start
    initial_host_ids.each { install_rhizome(it) }
    hop_wait_initial_rhizome_install
  end

  label def wait_initial_rhizome_install
    reap(:setup_vms_on_initial_hosts)
  end

  label def setup_vms_on_initial_hosts
    ssh_key = SshKey.generate
    vm_strands = VmHost.where(id: initial_host_ids).all.map do |vm_host|
      Prog::Vm::Nexus.assemble(
        ssh_key.public_key,
        vm_project_id,
        name: vm_host.ubid,
        unix_user: "rhizome",
        force_host_id: vm_host.id,
        location_id: vm_host.location_id,
        enable_ip4: true,
      )
    end
    update_stack(
      "initial_vm_ids" => vm_strands.map(&:id),
      "initial_vms_keypair" => Base64.strict_encode64(ssh_key.keypair),
    )
    hop_wait_vms_on_initial_hosts
  end

  label def wait_vms_on_initial_hosts
    nap 30 unless Strand.where(id: initial_vm_ids, label: "wait").count == initial_vm_ids.size
    hop_check_vms_on_initial_hosts
  end

  label def check_vms_on_initial_hosts
    Vm.eager(:location).where(id: initial_vm_ids).all do
      # id is used for ubid in a Clog.emit call
      sshable = Sshable.new_with_id(
        host: it.ip4_string,
        raw_private_key_1: SshKey.from_binary(Base64.strict_decode64(frame.fetch("initial_vms_keypair"))).keypair,
        unix_user: "rhizome",
      )
      sshable.cmd("sudo apt update && sudo apt install -y fio")
      sshable.cmd("fio --version")
    end
    hop_destroy_vms_on_initial_hosts
  end

  label def destroy_vms_on_initial_hosts
    Semaphore.incr(initial_vm_ids, "destroy")
    delete_from_stack("initial_vm_ids", "initial_vms_keypair")

    if frame["initial_github_runner_host_ids"].empty?
      update_stack("next_runner_time" => Time.now.to_i)
      hop_rollout_next
    else
      hop_install_on_initial_github_runners_hosts
    end
  end

  label def install_on_initial_github_runners_hosts
    frame.fetch("initial_github_runner_host_ids").each { install_rhizome(it) }
    update_stack("monitor_github_runners_until" => Time.now.to_i + 45 * 60)
    hop_wait_initial_github_runners_rhizome_install
  end

  label def wait_initial_github_runners_rhizome_install
    reap(:monitor_github_runners)
  end

  label def monitor_github_runners
    nap_until(frame["monitor_github_runners_until"])

    when_github_runners_work_set? do
      update_stack("next_runner_time" => Time.now.to_i)
      hop_rollout_next
    end

    nap(60 * 60)
  end

  label def wait
    reaper = lambda do |child|
      update_stack(
        "next_runner_time" => Time.now.to_i + 30,
        "completed" => (frame.fetch("completed") << child.stack.first["subject_id"]),
      )
    end

    reap(:rollout_next, reaper:)
  end

  label def rollout_next
    nap_until(frame["next_runner_time"])

    unless (next_vm_host_id = remaining_host_ids.shift)
      hop_destroy
    end

    install_rhizome(next_vm_host_id)
    update_stack("remaining_host_ids" => remaining_host_ids)
    hop_wait
  end

  label def destroy
    when_destroy_set? do
      pop("rollout completed")
    end

    nap(60 * 60 * 24 * 365)
  end

  def nap_until(time_int)
    now = Time.now.to_i
    time_left = time_int - now
    nap(time_left) if time_left > 0
  end

  def vm_project_id
    frame.fetch("vm_project_id")
  end

  def initial_host_ids
    frame.fetch("initial_host_ids")
  end

  def initial_vm_ids
    frame.fetch("initial_vm_ids")
  end

  def remaining_host_ids
    frame.fetch("remaining_host_ids")
  end

  def install_rhizome(vm_host_id)
    bud Prog::InstallRhizome, {"subject_id" => vm_host_id, "target_folder" => "host"}
  end
end
