# frozen_string_literal: true

require_relative "object_tag"
require "delegate"

class ObjectMetatag < DelegateClass(ObjectTag)
  def self.to_meta(ubid)
    ubid.sub(/\At0/, "t2")
  end

  def self.from_meta(ubid)
    ubid.sub(/\At2/, "t0")
  end

  def self.from_meta_uuid(uuid)
    UBID.to_uuid(from_meta(UBID.from_uuidish(uuid).to_s))
  end

  def self.to_meta_uuid(uuid)
    UBID.to_uuid(to_meta(UBID.from_uuidish(uuid).to_s))
  end

  # Designed solely for use with UBID.resolve_map
  def self.where(id:)
    ObjectTag.where(id: id.map { from_meta_uuid(_1) }).map(&:metatag)
  end

  # Designed solely for use with UBID.decode
  def self.[](id)
    ObjectTag[from_meta_uuid(id)]&.metatag
  end

  def self.filter_authorize_dataset(dataset, object_id)
    dataset.where(project_id: ObjectTag.dataset.where(id: from_meta_uuid(object_id)).select(:project_id))
  end

  def id = metatag_uuid

  def ubid = metatag_ubid
end
