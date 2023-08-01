# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_tags
  one_to_many :access_policies
  one_to_one :billing_info, key: :id, primary_key: :billing_info_id

  many_to_many :vms, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id
  many_to_many :private_subnets, join_table: AccessTag.table_name, left_key: :project_id, right_key: :hyper_tag_id

  dataset_module Authorization::Dataset

  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "project/#{ubid}"
  end

  include Authorization::TaggableMethods

  def user_ids
    access_tags_dataset.where(hyper_tag_table: Account.table_name.to_s).select_map(:hyper_tag_id)
  end

  def path
    "/project/#{ubid}"
  end
end
