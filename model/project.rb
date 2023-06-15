# frozen_string_literal: true

require_relative "../model"

class Project < Sequel::Model
  one_to_many :access_tags
  one_to_many :access_policies

  dataset_module Authorization::Dataset

  include ResourceMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  def user_ids
    access_tags_dataset.where(hyper_tag_table: Account.table_name.to_s).select_map(:hyper_tag_id)
  end

  def path
    "/project/#{ulid}"
  end
end
