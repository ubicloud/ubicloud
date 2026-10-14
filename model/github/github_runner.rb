# frozen_string_literal: true

require_relative "../../model"

class GithubRunner < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, class: :GithubInstallation
  many_to_one :repository, class: :GithubRepository, read_only: true
  many_to_one :vm, read_only: true
  one_through_one :project, join_table: :github_installation, left_key: :id, left_primary_key: :installation_id, read_only: true

  plugin ResourceMethods, encrypted_columns: :encoded_jit_config, redacted_columns: :workflow_job
  plugin SemaphoreMethods, :destroy, :skip_deregistration, :not_upgrade_premium, :spill_over, :spare_runner_provisioned
  include HealthMonitorMethods

  NOT_VM_ALLOCATED_RUNNER_LABELS = %w[start wait_concurrency_limit apply_custom_label_quota wait_capacity].freeze

  AWS_AMI_VERSIONS = [
    Config.github_ubuntu_2204_x64_aws_ami_version,
    Config.github_ubuntu_2404_x64_aws_ami_version,
    Config.github_ubuntu_2604_x64_aws_ami_version,
    Config.github_ubuntu_2204_arm64_aws_ami_version,
    Config.github_ubuntu_2404_arm64_aws_ami_version,
    Config.github_ubuntu_2604_arm64_aws_ami_version,
  ].freeze

  dataset_module do
    def total_active_runner_vcpus
      left_join(:strand, id: Sequel[:github_runner][:id])
        .exclude(Sequel[:strand][:label] => NOT_VM_ALLOCATED_RUNNER_LABELS)
        .select_map(Sequel[:github_runner][:label])
        .sum { Github.runner_labels[it]["vcpus"] }
    end

    def metal_active_runner_vcpus
      ds = self
      if (aws_location_id = Config.github_runner_aws_location_id)
        ds = ds.exclude(location_id: aws_location_id)
      end
      ds.total_active_runner_vcpus
    end

    def aws_active_runner_vcpus
      return 0 unless (aws_location_id = Config.github_runner_aws_location_id)
      where(location_id: aws_location_id)
        .total_active_runner_vcpus
    end
  end

  def self.aws_vm_usage(arch: nil)
    ds = Vm.where(boot_image: AWS_AMI_VERSIONS)
    ds = ds.where(arch:) if arch
    ds.get([
      Sequel.function(:coalesce, Sequel.function(:sum, :vcpus), 0).as(:vcpus),
      Sequel.function(:count).*.as(:runners),
    ])
  end

  def label_data
    @label_data ||= Github.runner_labels[label]
  end

  # AWS has no 30 vCPU instance size, so 30 vCPU runners get a 32 vCPU
  # instance, but the customer is still billed for 30 vCPUs.
  def aws_vcpus
    (label_data["vcpus"] == 30) ? 32 : label_data["vcpus"]
  end

  def metal_capacity_pool
    "#{label_data["arch"]}-#{label_data["family"]}"
  end

  def capacity_amounts(pool)
    if pool == GithubRunnerCapacity::SPILL
      {used_vcpus: aws_vcpus, used_runners: 1}
    else
      threads_per_core = (label_data["arch"] == "arm64") ? 1 : 2
      {
        used_cores: (label_data["vcpus"].to_f / threads_per_core).ceil,
        used_hugepages_1g: Validation.validate_vm_size(label_data["vm_size"], label_data["arch"]).memory_gib,
      }
    end
  end

  def reserve_metal_capacity(utilization)
    pool = metal_capacity_pool
    move_capacity(pool, GithubRunnerCapacity.metal_room(capacity_amounts(pool), utilization))
  end

  def reserve_spill_capacity
    move_capacity(GithubRunnerCapacity::SPILL, GithubRunnerCapacity.spill_room(capacity_amounts(GithubRunnerCapacity::SPILL)))
  end

  # Moves the runner's capacity reservation to the given pool, releasing the
  # one it holds. The condition limits the pool it moves to; without one, the
  # move always succeeds. Locks the runner row before the pool rows, and the
  # pool rows in name order.
  def move_capacity(to, condition = nil)
    # A plain read first, so runners waiting on a full pool do not queue on
    # its row lock.
    return false if condition && GithubRunnerCapacity.where(name: to).where(condition).empty?

    DB.transaction(savepoint: true) do
      from = this.for_no_key_update.get(:capacity_pool)
      next true if from == to

      this.update(capacity_pool: to)
      moved = [from, to].compact.sort.all? do |name|
        if name == to
          GithubRunnerCapacity.charge(to, capacity_amounts(to), condition)
        else
          GithubRunnerCapacity.refund(from, capacity_amounts(from))
        end
      end
      raise Sequel::Rollback unless moved

      true
    end
  end

  def release_capacity
    return unless (from = this.for_no_key_update.get(:capacity_pool))

    this.update(capacity_pool: nil)
    GithubRunnerCapacity.refund(from, capacity_amounts(from))
  end

  def repository_url
    "http://github.com/#{repository_name}"
  end

  def run_url
    "#{repository_url}/actions/runs/#{workflow_job["run_id"]}"
  end

  def job_url
    "#{run_url}/job/#{workflow_job["id"]}"
  end

  def runner_url
    "#{repository_url}/settings/actions/runners/#{runner_id}" if runner_id
  end

  def log_duration(message, duration)
    values = {ubid:, label:, repository_name:, duration: duration.round(3), conclusion: workflow_job&.dig("conclusion")}
    if vm
      values.merge!(vm_ubid: vm.ubid, arch: vm.arch, cores: vm.cores, vcpus: vm.vcpus, boot_image: vm.vm_storage_volumes.first&.boot_image&.version || vm.boot_image)
      if (vhost_block_backend_version = vm.vm_storage_volumes.first&.vhost_block_backend&.version)
        values[:vhost_block_backend_version] = vhost_block_backend_version
      end
      if (ch_version = vm.strand&.stack&.dig(0, "ch_version"))
        values[:ch_version] = ch_version
      end
      if vm.vm_host
        values[:vm_host_ubid] = vm.vm_host.ubid
        values[:data_center] = vm.vm_host.data_center
      end
      values[:instance_id] = vm.aws_instance.instance_id if vm.aws_instance
      values[:vm_pool_ubid] = VmPool[vm.pool_id].ubid if vm.pool_id
    end
    Clog.emit(message, {message => values})
  end

  def provision_spare_runner(force: false)
    return if !force && spare_runner_provisioned_set?
    incr_spare_runner_provisioned
    Prog::Github::GithubRunnerNexus.assemble(installation, repository_name:, label:).subject
  end

  def init_health_monitor_session
    {
      ssh_session: vm.sshable.start_fresh_session,
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      available_memory = session[:ssh_session].exec!("awk '/MemAvailable/ {print $2}' /proc/meminfo").chomp
      "up"
    rescue
      "down"
    end
    aggregate_readings(previous_pulse:, reading:, data: {available_memory:})
  end

  def page_on_sshable_failure?
    false
  end

  def custom_label
    GithubCustomLabel.first(name: actual_label, installation_id:)
  end

  def strand_label
    strand&.label
  end
end

# Table: github_runner
# Columns:
#  id                 | uuid                     | PRIMARY KEY
#  installation_id    | uuid                     |
#  repository_name    | text                     | NOT NULL
#  label              | text                     | NOT NULL
#  vm_id              | uuid                     |
#  runner_id          | bigint                   |
#  created_at         | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  ready_at           | timestamp with time zone |
#  workflow_job       | jsonb                    |
#  repository_id      | uuid                     |
#  allocated_at       | timestamp with time zone |
#  billed_vm_size     | text                     |
#  actual_label       | text                     |
#  location_id        | uuid                     |
#  encoded_jit_config | text                     |
#  capacity_pool      | text                     |
# Indexes:
#  github_runner_pkey                  | PRIMARY KEY btree (id)
#  github_runner_vm_id_key             | UNIQUE btree (vm_id)
#  github_runner_installation_id_index | btree (installation_id)
# Check constraints:
#  location_id_and_vm_id_set_together | (location_id IS NOT NULL AND vm_id IS NOT NULL OR location_id IS NULL AND vm_id IS NULL)
# Foreign key constraints:
#  github_runner_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_runner_location_id_fkey     | (location_id) REFERENCES location(id)
#  github_runner_repository_id_fkey   | (repository_id) REFERENCES github_repository(id)
