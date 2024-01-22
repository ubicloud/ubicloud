# frozen_string_literal: true

require_relative "../../model"

class PostgresFirewallRule < Sequel::Model
  many_to_one :postgres_resource, key: :postgres_resource_id
  dataset_module Authorization::Dataset

  include ResourceMethods
end
