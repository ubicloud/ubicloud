# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_tags
  one_to_many :access_policies
  one_to_one :billing_info, key: :id, primary_key: :billing_info_id
  one_to_many :usage_alerts
  one_to_many :github_installations

  many_to_many :accounts, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :vms, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :minio_clusters, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :private_subnets, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :postgres_resources, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :firewalls, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :load_balancers, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :inference_endpoints, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id

  one_to_many :invoices, order: Sequel.desc(:created_at)
  one_to_many :quotas, class: :ProjectQuota, key: :project_id
  one_to_many :invitations, class: :ProjectInvitation, key: :project_id
  one_to_many :api_keys, key: :owner_id, class: :ApiKey, conditions: {owner_table: "project"}

  dataset_module Authorization::Dataset
  dataset_module Pagination

  plugin :association_dependencies, access_tags: :destroy, access_policies: :destroy, billing_info: :destroy, github_installations: :destroy, api_keys: :destroy

  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "project/#{ubid}"
  end

  include Authorization::TaggableMethods

  def has_valid_payment_method?
    return true unless Config.stripe_secret_key
    !!billing_info&.payment_methods&.any?
  end

  def default_location
    location_max_capacity = DB[:vm_host]
      .where(location: Option.locations.map { _1.name })
      .where(allocation_state: "accepting")
      .select_group(:location)
      .order { sum(Sequel[:total_cores] - Sequel[:used_cores]).desc }
      .first

    if location_max_capacity.nil?
      Option.locations.first.name
    else
      location_max_capacity[:location]
    end
  end

  def path
    "/project/#{ubid}"
  end

  def has_resources
    access_tags_dataset.exclude(hyper_tag_table: [Account.table_name.to_s, Project.table_name.to_s, AccessTag.table_name.to_s]).count > 0 || github_installations.flat_map(&:runners).count > 0
  end

  def soft_delete
    DB.transaction do
      access_tags_dataset.destroy
      access_policies_dataset.destroy
      github_installations.each { Prog::Github::DestroyGithubInstallation.assemble(_1) }

      # We still keep the project object for billing purposes.
      # These need to be cleaned up manually once in a while.
      # Don't forget to clean up billing info and payment methods.
      update(visible: false)
    end
  end

  def current_invoice
    begin_time = invoices.first&.end_time || Time.new(Time.now.year, Time.now.month, 1)
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

    Invoice.new(project_id: id, content: content, begin_time: begin_time, end_time: end_time, created_at: Time.now, status: "current")
  end

  def current_resource_usage(resource_type)
    case resource_type
    when "VmCores" then vms.sum(&:cores)
    when "GithubRunnerCores" then github_installations.sum(&:total_active_runner_cores)
    when "PostgresCores" then postgres_resources.flat_map { _1.servers.map { |s| s.vm.cores } }.sum
    else
      raise "Unknown resource type: #{resource_type}"
    end
  end

  def effective_quota_value(resource_type)
    default_quota = ProjectQuota.default_quotas[resource_type]
    override_quota_value = quotas_dataset.first(quota_id: default_quota["id"])&.value
    override_quota_value || default_quota["#{reputation}_value"]
  end

  def quota_available?(resource_type, requested_additional_usage)
    effective_quota_value(resource_type) >= current_resource_usage(resource_type) + requested_additional_usage
  end

  def create_api_key(used_for: "inference_endpoint")
    ApiKey.create_with_id(owner_table: Project.table_name, owner_id: id, used_for: used_for)
  end

  def self.feature_flag(*flags, into: self)
    flags.map(&:to_s).each do |flag|
      into.module_eval do
        define_method :"set_ff_#{flag}" do |value|
          update(feature_flags: feature_flags.merge({flag => value}))
        end

        define_method :"get_ff_#{flag}" do
          feature_flags[flag]
        end
      end
    end
  end

  feature_flag :postgresql_base_image, :vm_public_ssh_keys, :transparent_cache, :location_latitude_fra
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
#  reputation      | project_reputation       | NOT NULL DEFAULT 'new'::project_reputation
# Indexes:
#  project_pkey                      | PRIMARY KEY btree (id)
#  project_right(id::text, 10)_index | UNIQUE btree ("right"(id::text, 10))
# Check constraints:
#  max_discount_amount | (discount <= 100)
#  min_credit_amount   | (credit >= 0::numeric)
# Foreign key constraints:
#  project_billing_info_id_fkey | (billing_info_id) REFERENCES billing_info(id)
# Referenced By:
#  access_policy       | access_policy_project_id_fkey       | (project_id) REFERENCES project(id)
#  access_tag          | access_tag_project_id_fkey          | (project_id) REFERENCES project(id)
#  github_installation | github_installation_project_id_fkey | (project_id) REFERENCES project(id)
#  inference_endpoint  | inference_endpoint_project_id_fkey  | (project_id) REFERENCES project(id)
#  usage_alert         | usage_alert_project_id_fkey         | (project_id) REFERENCES project(id)
