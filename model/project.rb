# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_control_entries, read_only: true
  one_to_many :subject_tags, order: :name, read_only: true
  one_to_many :action_tags, order: :name, read_only: true
  one_to_many :object_tags, order: :name, read_only: true
  many_to_one :billing_info
  one_to_many :usage_alerts, read_only: true
  one_to_many :github_installations, read_only: true
  many_to_many :github_runners, join_table: :github_installation, right_key: :id, right_primary_key: :installation_id, read_only: true

  many_to_many :accounts, join_table: :access_tag, right_key: :hyper_tag_id
  many_to_many :nics, join_table: :private_subnet, right_key: :id, right_primary_key: :private_subnet_id, read_only: true
  one_to_many :vms, read_only: true
  one_to_many :minio_clusters, read_only: true
  one_to_many :private_subnets, read_only: true
  one_to_many :postgres_resources, read_only: true
  one_to_many :firewalls, read_only: true
  one_to_many :load_balancers, read_only: true
  one_to_many :inference_endpoints, read_only: true
  one_to_many :kubernetes_clusters, read_only: true
  one_to_many :machine_images, read_only: true
  one_to_many :ssh_public_keys, order: :name, remover: nil, clearer: nil

  RESOURCE_ASSOCIATIONS = %i[vms minio_clusters private_subnets postgres_resources firewalls load_balancers kubernetes_clusters machine_images github_runners]
  RESOURCE_ASSOCIATION_DATASET_METHODS = RESOURCE_ASSOCIATIONS.map { :"#{it}_dataset" }

  one_to_many :invoices, order: Sequel.desc(:created_at), read_only: true
  one_to_many :quotas, class: :ProjectQuota, remover: nil, clearer: nil
  one_to_many :invitations, class: :ProjectInvitation, remover: nil, clearer: nil
  one_to_many :api_keys, key: :owner_id, conditions: {owner_table: "project"}, read_only: true
  one_to_many :locations, read_only: true
  many_to_many :payment_methods, join_table: :billing_info, left_primary_key: :billing_info_id, left_key: :id, right_key: :id, right_primary_key: :billing_info_id, read_only: true

  dataset_module Pagination

  dataset_module do
    def first_project_with_resources
      all = self.all
      RESOURCE_ASSOCIATIONS.each do
        if (obj = Project.association_reflection(it).associated_class.first(project: all))
          return obj.project
        end
      end

      nil
    end
  end

  plugin :association_dependencies,
    access_control_entries: :destroy,
    accounts: :nullify,
    action_tags: :destroy,
    api_keys: :destroy,
    billing_info: :destroy,
    github_installations: :destroy,
    locations: :destroy,
    object_tags: :destroy,
    ssh_public_keys: :destroy,
    subject_tags: :destroy

  plugin ResourceMethods

  def has_valid_payment_method?
    return true unless Config.stripe_secret_key
    return true if discount == 100

    !!billing_info&.payment_methods&.any? || (!!billing_info && credit > 0)
  end

  def default_location
    location_max_capacity = DB[:vm_host]
      .join(:location, id: :location_id)
      .where(allocation_state: "accepting")
      .select_group(:location_id)
      .reverse { sum(Sequel[:total_cores] - Sequel[:used_cores]) }
      .single_value

    cond = location_max_capacity ? {id: location_max_capacity} : {visible: true}
    Location[cond].display_name
  end

  def disassociate_subject(subject_id)
    DB[:applied_subject_tag].where(tag_id: subject_tags_dataset.select(:id), subject_id:).delete
    AccessControlEntry.where(project_id: id, subject_id:).destroy
  end

  def path
    "/project/#{ubid}"
  end

  def has_resources?
    RESOURCE_ASSOCIATION_DATASET_METHODS.any? { !send(it).empty? }
  end

  def insert_project_discount_code(discount)
    hash = ProjectDiscountCode.dataset.returning.insert(
      id: ProjectDiscountCode.generate_uuid,
      project_id: id,
      discount_code_id: discount.id
    ).first
    ProjectDiscountCode.call(hash)
  end

  def soft_delete
    DB.transaction do
      DB[:access_tag].where(project_id: id).delete
      access_control_entries_dataset.destroy
      %w[subject action object].each do |tag_type|
        dataset = send(:"#{tag_type}_tags_dataset")
        DB[:"applied_#{tag_type}_tag"].where(tag_id: dataset.select(:id)).delete
        dataset.destroy
      end
      DB.ignore_duplicate_queries do
        github_installations.each { Prog::Github::DestroyGithubInstallation.assemble(it) }
      end

      # We still keep the project object for billing purposes.
      # These need to be cleaned up manually once in a while.
      # Don't forget to clean up billing info and payment methods.
      update(visible: false)
    end
  end

  def active?
    visible && accounts_dataset.exclude(suspended_at: nil).empty?
  end

  def current_invoice
    begin_time = invoices_dataset.get(:end_time) || Time.new(Time.now.year, Time.now.month, 1)
    end_time = Time.now

    if (invoice = InvoiceGenerator.new(begin_time, end_time, project_ids: [id]).run.first)
      return invoice
    end

    content = {
      "resources" => [],
      "subtotal" => 0.0,
      "credit" => 0.0,
      "discount" => 0.0,
      "cost" => 0.0
    }

    Invoice.new(project_id: id, content:, begin_time:, end_time:, created_at: Time.now, status: "current")
  end

  def current_resource_usage(resource_type)
    case resource_type
    when "VmVCpu" then vms_dataset.sum(:vcpus) || 0
    when "GithubRunnerVCpu" then GithubRunner.where(installation_id: github_installations_dataset.select(:id)).total_active_runner_vcpus
    when "PostgresVCpu" then postgres_resources_dataset.association_join(servers: :vm).sum(:vcpus) || 0
    when "KubernetesVCpu" then kubernetes_clusters_dataset.select(Sequel[:kubernetes_cluster][:cp_node_count].as(:node_count), Sequel[:kubernetes_cluster][:target_node_size])
      .union(kubernetes_clusters_dataset.association_join(:nodepools).select(:node_count, Sequel[:nodepools][:target_node_size]), all: true)
      .all.sum { it[:node_count] * Validation.validate_vm_size(it[:target_node_size], "x64").vcpus } || 0
    when "MachineImageCount" then machine_images_dataset.count
    when "MachineImageStorage" then MachineImageVersion.where(machine_image_id: machine_images_dataset.select(:id)).sum(:size_gib) || 0
    else
      raise "Unknown resource type: #{resource_type}"
    end
  end

  def effective_quota_value(resource_type)
    DB.ignore_duplicate_queries do
      default_quota = ProjectQuota.default_quotas[resource_type]
      override_quota_value = quotas_dataset.first(quota_id: default_quota["id"])&.value
      override_quota_value || default_quota["#{reputation}_value"]
    end
  end

  def quota_available?(resource_type, requested_additional_usage)
    effective_quota_value(resource_type) >= current_resource_usage(resource_type) + requested_additional_usage
  end

  def validate
    super
    if new? || changed_columns.include?(:name)
      validates_format(%r{\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z}i, :name, message: "must be less than 64 characters and only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number")
    end
  end

  def default_private_subnet(location)
    name = "default-#{location.display_name[0, 55]}"
    location_id = location.id
    ps = private_subnets_dataset.first(location_id:, name:)
    ps || Prog::Vnet::SubnetNexus.assemble(id, name:, location_id:).subject
  end

  def total_github_amount(begin_time, end_time)
    BillingRecord.total_amount_by_rate(project_id: id, billing_rate_id: Github::MINUTE_BILLING_RATE_IDS, begin_time:, end_time:)
      .sum { |billing_rate_id, total_amount| (total_amount * BillingRate.from_id(billing_rate_id)["unit_price"]) }
  end

  def self.feature_flag(*flags, into: self)
    flags.map!(&:to_s).each do |flag|
      into.module_eval do
        define_method :"set_ff_#{flag}" do |value|
          update(feature_flags: feature_flags.merge({flag => value}).slice(*flags))
        end

        define_method :"get_ff_#{flag}" do
          feature_flags[flag]
        end
      end
    end
  end

  feature_flag(
    :access_all_cache_scopes,
    :allocator_diagnostics,
    :aws_alien_runners_ratio,
    :aws_cloudwatch_logs,
    :enable_c6gd,
    :enable_i7i,
    :enable_i7ie,
    :enable_i8ge,
    :enable_m6id,
    :enable_m6gd,
    :enable_r8gd,
    :enable_r6gd,
    :enable_r6id,
    :free_runner_upgrade_until,
    :gpu_runner,
    :gpu_vm,
    :ipv6_disabled,
    :postgres_hostname_override,
    :postgres_init_script,
    :postgres_lantern,
    :postgres_paradedb,
    :private_locations,
    :skip_runner_pool,
    :spill_to_alien_runners,
    :visible_locations,
    :vm_public_ssh_keys,
    :postgres_aws_use_different_azs_for_standbys,
    :cache_proxy_download_url,
    :machine_image
  )
end

# Table: project
# Columns:
#  id              | uuid                     | PRIMARY KEY
#  name            | text                     | NOT NULL
#  visible         | boolean                  | NOT NULL DEFAULT true
#  billing_info_id | uuid                     |
#  credit          | numeric                  | NOT NULL DEFAULT 0
#  discount        | integer                  | NOT NULL DEFAULT 0
#  created_at      | timestamp with time zone | NOT NULL DEFAULT now()
#  feature_flags   | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  billable        | boolean                  | NOT NULL DEFAULT true
#  reputation      | text                     | NOT NULL DEFAULT 'new'::text
# Indexes:
#  project_pkey                      | PRIMARY KEY btree (id)
#  project_right(id::text, 10)_index | UNIQUE btree ("right"(id::text, 10))
# Check constraints:
#  max_discount_amount | (discount <= 100)
#  min_credit_amount   | (credit >= 0::numeric)
#  reputation_check    | (reputation = ANY (ARRAY['new'::text, 'verified'::text, 'limited'::text]))
# Foreign key constraints:
#  project_billing_info_id_fkey | (billing_info_id) REFERENCES billing_info(id)
# Referenced By:
#  access_control_entry      | access_control_entry_project_id_fkey      | (project_id) REFERENCES project(id)
#  access_tag                | access_tag_project_id_fkey                | (project_id) REFERENCES project(id)
#  account_default_project   | account_default_project_project_id_fkey   | (project_id) REFERENCES project(id) ON DELETE CASCADE
#  action_tag                | action_tag_project_id_fkey                | (project_id) REFERENCES project(id)
#  api_key                   | api_key_project_id_fkey                   | (project_id) REFERENCES project(id)
#  firewall                  | firewall_project_id_fkey                  | (project_id) REFERENCES project(id)
#  github_installation       | github_installation_project_id_fkey       | (project_id) REFERENCES project(id)
#  inference_endpoint        | inference_endpoint_project_id_fkey        | (project_id) REFERENCES project(id)
#  inference_router          | inference_router_project_id_fkey          | (project_id) REFERENCES project(id)
#  kubernetes_cluster        | kubernetes_cluster_project_id_fkey        | (project_id) REFERENCES project(id)
#  load_balancer             | load_balancer_project_id_fkey             | (project_id) REFERENCES project(id)
#  location                  | location_project_id_fkey                  | (project_id) REFERENCES project(id)
#  minio_cluster             | minio_cluster_project_id_fkey             | (project_id) REFERENCES project(id)
#  object_tag                | object_tag_project_id_fkey                | (project_id) REFERENCES project(id)
#  private_subnet            | private_subnet_project_id_fkey            | (project_id) REFERENCES project(id)
#  project_discount_code     | project_discount_code_project_id_fkey     | (project_id) REFERENCES project(id)
#  ssh_public_key            | ssh_public_key_project_id_fkey            | (project_id) REFERENCES project(id)
#  subject_tag               | subject_tag_project_id_fkey               | (project_id) REFERENCES project(id)
#  usage_alert               | usage_alert_project_id_fkey               | (project_id) REFERENCES project(id)
#  victoria_metrics_resource | victoria_metrics_resource_project_id_fkey | (project_id) REFERENCES project(id)
#  vm                        | vm_project_id_fkey                        | (project_id) REFERENCES project(id)
