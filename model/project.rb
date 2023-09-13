# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_tags
  one_to_many :access_policies
  one_to_one :billing_info, key: :id, primary_key: :billing_info_id
  one_to_many :github_installations

  many_to_many :vms, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :private_subnets, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id

  one_to_many :invoices

  dataset_module Authorization::Dataset

  plugin :association_dependencies, access_tags: :destroy, access_policies: :destroy, billing_info: :destroy

  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "project/#{ubid}"
  end

  include Authorization::TaggableMethods

  def user_ids
    access_tags_dataset.where(hyper_tag_table: Account.table_name.to_s).select_map(:hyper_tag_id)
  end

  def has_valid_payment_method?
    return true unless Config.stripe_secret_key
    !!billing_info&.payment_methods&.any?
  end

  def path
    "/project/#{ubid}"
  end
end
