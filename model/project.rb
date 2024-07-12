# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_tags
  one_to_many :access_policies
  one_to_one :billing_info, key: :id, primary_key: :billing_info_id
  one_to_many :usage_alerts
  one_to_many :github_installations

  many_to_many :accounts, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :vms, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :minio_clusters, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :private_subnets, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :postgres_resources, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :firewalls, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :load_balancers, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id

  one_to_many :invoices, order: Sequel.desc(:created_at)

  dataset_module Authorization::Dataset
  dataset_module Pagination

  plugin :association_dependencies, access_tags: :destroy, access_policies: :destroy, billing_info: :destroy, github_installations: :destroy

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

      github_installations.each do
        Github.app_client.delete_installation(_1.installation_id)
        _1.repositories.each(&:incr_destroy)
        _1.destroy
      end

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

  def self.feature_flag(*flags)
    flags.map(&:to_s).each do |flag|
      define_method :"set_ff_#{flag}" do |value|
        update(feature_flags: feature_flags.merge({flag => value}))
      end

      define_method :"get_ff_#{flag}" do
        feature_flags[flag]
      end
    end
  end

  feature_flag :postgresql_base_image
end
