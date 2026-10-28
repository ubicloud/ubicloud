# frozen_string_literal: true

require_relative "../../model"

class GithubRunner < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, class: :GithubInstallation
  many_to_one :repository, class: :GithubRepository, read_only: true
  many_to_one :vm, read_only: true
  one_through_one :project, join_table: :github_installation, left_key: :id, left_primary_key: :installation_id, read_only: true
  many_to_one :active_workflow_run, class: :GithubActiveWorkflowRun, key: [:repository_id, :run_id, :run_attempt], primary_key: [:repository_id, :run_id, :run_attempt], read_only: true
  many_to_one :completed_workflow_run, class: :GithubCompletedWorkflowRun, key: [:repository_id, :run_id, :run_attempt], primary_key: [:repository_id, :run_id, :run_attempt], read_only: true

  plugin ResourceMethods, encrypted_columns: :encoded_jit_config, redacted_columns: :workflow_job
  plugin SemaphoreMethods, :destroy, :skip_deregistration, :not_upgrade_premium, :spill_over, :spare_runner_provisioned

  NOT_VM_ALLOCATED_RUNNER_LABELS = %w[start wait_concurrency_limit apply_custom_label_quota].freeze

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
        ds = ds.where(Sequel.~(location_id: aws_location_id) | {location_id: nil})
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
    return [0, 0] unless (location_id = Config.github_runner_aws_location_id)
    ds = Vm.where(project_id: Config.github_runner_service_project_id, location_id:)
    ds = ds.where(arch:) if arch
    ds.get([
      Sequel.function(:coalesce, Sequel.function(:sum, :vcpus), 0).as(:vcpus),
      Sequel.function(:count).*.as(:runners),
    ])
  end

  def label_data
    @label_data ||= Github.runner_labels[label]
  end

  def repository_url
    "http://github.com/#{repository_name}"
  end

  def run_url
    "#{repository_url}/actions/runs/#{run_id}"
  end

  def job_url
    "#{run_url}/job/#{job_id}"
  end

  def runner_url
    "#{repository_url}/settings/actions/runners/#{runner_id}" if runner_id
  end

  def log_duration(message, duration)
    values = {ubid:, label:, repository_name:, duration: duration.round(3), conclusion:}
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
    unless force
      return if spare_runner_provisioned_set? || project.cutoff?
    end
    incr_spare_runner_provisioned
    Prog::Github::GithubRunnerNexus.assemble(installation, repository_name:, label:).subject
  end

  def custom_label
    GithubCustomLabel.first(name: actual_label, installation_id:)
  end

  def strand_label
    strand&.label
  end

  def has_workflow_job_info?
    # Can be changed to only job_id after all GitHubRunner with
    # with workflow_job set also have these other columns set
    !!(job_id || workflow_job)
  end

  def workflow_run_create_date
    unless (create_date = active_workflow_run_dataset.get(:create_date))
      today = Time.now.utc.to_date
      create_date = completed_workflow_run_dataset
        .where(create_date: (today - 6)..today)
        .get(:create_date)
    end

    create_date
  end

  # Methods below are temporary and can be removed after all GitHubRunner
  # with workflow_job set also have these other columns set

  def job_id
    super || (self.job_id = workflow_job&.[]("id"))
  end

  def run_id
    super || (self.run_id = workflow_job&.[]("run_id"))
  end

  def head_branch
    super || (self.head_branch = workflow_job&.[]("head_branch"))
  end

  def workflow_name
    super || (self.workflow_name = workflow_job&.[]("workflow_name"))
  end

  def job_name
    super || (self.job_name = workflow_job&.[]("name"))
  end

  def job_created_at
    if (res = super)
      return res
    end

    self.job_created_at = workflow_job&.[]("created_at")
    super
  end

  def job_started_at
    if (res = super)
      return res
    end

    self.job_started_at = workflow_job&.[]("started_at")
    super
  end

  def job_completed_at
    if (res = super)
      return res
    end

    self.job_completed_at = workflow_job&.[]("completed_at")
    super
  end

  def status
    super || (self.status = workflow_job&.[]("status"))
  end

  def conclusion
    super || (self.conclusion = workflow_job&.[]("conclusion"))
  end

  # Allow disabling use of DeletedRecord when destroying GithubRunner.
  # If we insert a GithubCompletedWorkflowJob, then there is no point
  # creating a DeletedRecord.
  def skip_deleted_record!
    @skip_deleted_record = true
  end

  private

  def create_deleted_record
    super unless @skip_deleted_record
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
#  job_id             | bigint                   |
#  run_id             | bigint                   |
#  run_attempt        | smallint                 |
#  head_branch        | text                     |
#  workflow_name      | text                     |
#  job_name           | text                     |
#  completed_at       | timestamp with time zone |
#  job_created_at     | timestamp with time zone |
#  job_started_at     | timestamp with time zone |
#  job_completed_at   | timestamp with time zone |
#  status             | text                     |
#  conclusion         | text                     |
#  cache_scope        | text                     |
# Indexes:
#  github_runner_pkey                                          | PRIMARY KEY btree (id)
#  github_runner_vm_id_key                                     | UNIQUE btree (vm_id)
#  github_runner_installation_id_index                         | btree (installation_id)
#  github_runner_location_id_private_idx                       | btree (location_id) WHERE location_id IS NOT NULL AND (location_id <> ALL (ARRAY['caa7a807-36c5-8420-a75c-f906839dad71'::uuid, '1f214853-0bc4-8020-b910-dffb867ef44f'::uuid, '6b9ef786-b842-8420-8c65-c25e3d4bdf3d'::uuid, 'e0865080-9a3d-8020-a812-f5817c7afe7f'::uuid]))
#  github_runner_repository_id_index                           | btree (repository_id)
#  github_runner_repository_id_run_id_run_attempt_job_id_index | btree (repository_id, run_id, run_attempt, job_id)
# Check constraints:
#  location_id_and_vm_id_set_together | (location_id IS NOT NULL AND vm_id IS NOT NULL OR location_id IS NULL AND vm_id IS NULL)
# Foreign key constraints:
#  github_runner_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_runner_location_id_fkey     | (location_id) REFERENCES location(id)
#  github_runner_repository_id_fkey   | (repository_id) REFERENCES github_repository(id)
