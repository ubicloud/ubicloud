# frozen_string_literal: true

class Prog::RolloutRhizome < Prog::Base
  semaphore :pause, :github_runners_work, :destroy
  frame_reader :vm_project_id, :initial_host_ids, :initial_github_runner_host_ids, :auto_exit
  frame_accessor :next_runner_time, :remaining_host_ids, :completed, :monitor_github_runners_until,
    :initial_vm_ids, :initial_vms_keypair

  def self.assemble(vm_project_id: Config.rollouts_project_id, auto_exit: false, started_by: nil)
    vm_host_ds = VmHost
      .order(Sequel.function(:random))
      .where(allocation_state: "accepting")
      .where { total_cores >= used_cores + 4 }

    vm_memory_gib = Option::VmSizes.find { it.name == Prog::Vm::Nexus::DEFAULT_SIZE && it.arch == "x64" }.memory_gib

    initial_vm_host_ds = vm_host_ds
      .where { total_hugepages_1g >= used_hugepages_1g + vm_memory_gib }
      .where(
        DB[:ipv4_address]
          .left_join(:assigned_vm_address, [:ip])
          .join(:address, [:cidr])
          .where(Sequel[:assigned_vm_address][:ip] => nil)
          .where(Sequel[:address][:routed_to_host_id] => Sequel[:vm_host][:id])
          .exists,
      )

    initial_host_ids = [
      initial_vm_host_ds.where(location_id: Location::HETZNER_FSN1_ID).get(:id),
      initial_vm_host_ds.where(location_id: Location::LEASEWEB_WDC02_ID).get(:id),
    ]
    initial_host_ids.compact!

    initial_github_runner_host_ds = vm_host_ds
      .where(location_id: Location::GITHUB_RUNNERS_ID)
      .limit(2)

    initial_github_runner_host_ids = DB.ignore_duplicate_queries do
      %w[x64 arm64].freeze.flat_map do |arch|
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
        "auto_exit" => auto_exit,
        "started_by" => started_by,
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
    self.initial_vm_ids = vm_strands.map(&:id)
    self.initial_vms_keypair = Base64.strict_encode64(ssh_key.keypair)
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
        raw_private_key_1: SshKey.from_binary(Base64.strict_decode64(initial_vms_keypair)).keypair,
        unix_user: "rhizome",
      )
      sshable.cmd("sudo apt update && sudo apt install -y fio")
      sshable.cmd("fio --version")
    end
    hop_destroy_vms_on_initial_hosts
  end

  label def destroy_vms_on_initial_hosts
    Vm.incr_destroy(initial_vm_ids)
    delete_from_stack("initial_vm_ids", "initial_vms_keypair")

    if initial_github_runner_host_ids.empty?
      self.next_runner_time = Time.now.to_i
      hop_rollout_next
    else
      hop_install_on_initial_github_runners_hosts
    end
  end

  label def install_on_initial_github_runners_hosts
    initial_github_runner_host_ids.each { install_rhizome(it) }
    self.monitor_github_runners_until = Time.now.to_i + 45 * 60
    hop_wait_initial_github_runners_rhizome_install
  end

  label def wait_initial_github_runners_rhizome_install
    reap(:monitor_github_runners)
  end

  label def monitor_github_runners
    nap_until(monitor_github_runners_until)

    when_github_runners_work_set? do
      self.next_runner_time = Time.now.to_i
      hop_rollout_next
    end

    nap(60 * 60)
  end

  label def wait
    reaper = lambda do |child|
      self.next_runner_time = Time.now.to_i + 30
      # Mutation works here, as previous line sets strand.modified!(:stack)
      completed << child.stack.first["subject_id"]
    end

    reap(:rollout_next, reaper:)
  end

  label def rollout_next
    nap_until(next_runner_time)

    unless (next_vm_host_id = remaining_host_ids.shift)
      hop_destroy
    end

    install_rhizome(next_vm_host_id)
    strand.modified!(:stack)
    hop_wait
  end

  label def destroy
    pop("rollout completed") if auto_exit || destroy_set?

    nap(60 * 60 * 24 * 365)
  end

  def nap_until(time_int)
    now = Time.now.to_i
    time_left = time_int - now
    nap(time_left) if time_left > 0
  end

  def install_rhizome(vm_host_id)
    bud Prog::InstallRhizome, {"subject_id" => vm_host_id, "target_folder" => "host"}
  end
end
