# frozen_string_literal: true

require_relative "../../model"

class PostgresMetricDestination < Sequel::Model
  many_to_one :postgres_resource, key: :postgres_resource_id

  include ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :password
  end

  def self.ubid_type
    UBID::TYPE_ETC
  end
end
