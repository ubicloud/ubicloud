# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_control_entries
  one_to_many :subject_tags, order: :name
  one_to_many :action_tags, order: :name
  one_to_many :object_tags, order: :name
  one_to_one :billing_info, key: :id, primary_key: :billing_info_id
  one_to_many :usage_alerts
  one_to_many :github_installations
  many_through_many :github_runners, [[:github_installation, :project_id, :id], [:github_runner, :installation_id, :id]]

  many_to_many :accounts, join_table: :access_tag, left_key: :project_id, right_key: :hyper_tag_id
  one_to_many :vms
  one_to_many :minio_clusters
  one_to_many :private_subnets
  one_to_many :postgres_resources
  one_to_many :firewalls
  one_to_many :load_balancers
  one_to_many :inference_endpoints
  one_to_many :kubernetes_clusters

  RESOURCE_ASSOCIATIONS = %i[vms minio_clusters private_subnets postgres_resources firewalls load_balancers kubernetes_clusters]

  one_to_many :invoices, order: Sequel.desc(:created_at)
  one_to_many :quotas, class: :ProjectQuota, key: :project_id
  one_to_many :invitations, class: :ProjectInvitation, key: :project_id
  one_to_many :api_keys, key: :owner_id, class: :ApiKey, conditions: {owner_table: "project"}

  dataset_module Pagination

  plugin :association_dependencies, accounts: :nullify, billing_info: :destroy, github_installations: :destroy, api_keys: :destroy, access_control_entries: :destroy, subject_tags: :destroy, action_tags: :destroy, object_tags: :destroy

  include ResourceMethods

  def has_valid_payment_method?
    return true unless Config.stripe_secret_key
    !!billing_info&.payment_methods&.any? || (!!billing_info && credit > 0)
  end

  def default_location
    location_max_capacity = DB[:vm_host]
      .join(:location, id: :location_id)
      .where(allocation_state: "accepting")
      .select_group(:location_id)
      .order { sum(Sequel[:total_cores] - Sequel[:used_cores]).desc }
      .first

    if location_max_capacity.nil?
      Location.find(visible: true).display_name
    else
      Location[location_max_capacity[:location_id]].display_name
    end
  end

  def disassociate_subject(subject_id)
    DB[:applied_subject_tag].where(tag_id: subject_tags_dataset.select(:id), subject_id:).delete
    AccessControlEntry.where(project_id: id, subject_id:).destroy
  end

  def path
    "/project/#{ubid}"
  end

  def has_resources
    RESOURCE_ASSOCIATIONS.any? { !send(:"#{_1}_dataset").empty? } || github_installations.flat_map(&:runners).count > 0
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
      github_installations.each { Prog::Github::DestroyGithubInstallation.assemble(_1) }

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
    when "VmVCpu" then vms.sum(&:vcpus)
    when "GithubRunnerVCpu" then github_installations.sum(&:total_active_runner_vcpus)
    when "PostgresVCpu" then postgres_resources.flat_map { _1.servers.map { |s| s.vm.vcpus } }.sum
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

  def validate
    super
    if new? || changed_columns.include?(:name)
      validates_format(%r{\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\z}i, :name, message: "must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number")
    end
  end

  def default_private_subnet(location)
    name = "default-#{location.display_name}"
    ps = private_subnets_dataset.first(:location_id => location.id, Sequel[:private_subnet][:name] => name)
    ps || Prog::Vnet::SubnetNexus.assemble(id, name: name, location_id: location.id).subject
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

  feature_flag :vm_public_ssh_keys, :transparent_cache, :location_latitude_fra, :access_all_cache_scopes, :use_slices_for_allocation, :allocator_diagnostics, :kubernetes
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
#  access_control_entry | access_control_entry_project_id_fkey | (project_id) REFERENCES project(id)
#  access_tag           | access_tag_project_id_fkey           | (project_id) REFERENCES project(id)
#  action_tag           | action_tag_project_id_fkey           | (project_id) REFERENCES project(id)
#  api_key              | api_key_project_id_fkey              | (project_id) REFERENCES project(id)
#  firewall             | firewall_project_id_fkey             | (project_id) REFERENCES project(id)
#  github_installation  | github_installation_project_id_fkey  | (project_id) REFERENCES project(id)
#  inference_endpoint   | inference_endpoint_project_id_fkey   | (project_id) REFERENCES project(id)
#  kubernetes_cluster   | kubernetes_cluster_project_id_fkey   | (project_id) REFERENCES project(id)
#  load_balancer        | load_balancer_project_id_fkey        | (project_id) REFERENCES project(id)
#  minio_cluster        | minio_cluster_project_id_fkey        | (project_id) REFERENCES project(id)
#  object_tag           | object_tag_project_id_fkey           | (project_id) REFERENCES project(id)
#  private_subnet       | private_subnet_project_id_fkey       | (project_id) REFERENCES project(id)
#  subject_tag          | subject_tag_project_id_fkey          | (project_id) REFERENCES project(id)
#  usage_alert          | usage_alert_project_id_fkey          | (project_id) REFERENCES project(id)
#  vm                   | vm_project_id_fkey                   | (project_id) REFERENCES project(id)
