# frozen_string_literal: true

require_relative "../../model"

class GithubCacheEntry < Sequel::Model
  many_to_one :repository, key: :repository_id, class: :GithubRepository

  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def blob_key
    "cache/#{ubid}"
  end
end
