# frozen_string_literal: true

require_relative "../../model"

class PostgresMigration < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :project
  many_to_one :target_resource, class: :PostgresResource
  many_to_one :vm, read_only: true
  many_to_one :location, read_only: true
  one_to_many :migration_databases, class: :PostgresMigrationDatabase, key: :postgres_migration_id

  plugin :association_dependencies, migration_databases: :destroy
  dataset_module Pagination

  plugin ResourceMethods,
    encrypted_columns: [:source_connection_string, :source_password]
  plugin SemaphoreMethods, :destroy, :cancel, :start_migration

  def display_state
    status.gsub("_", " ").capitalize
  end

  def selected_databases
    migration_databases.select(&:selected)
  end

  def total_size_bytes
    migration_databases.sum(&:size_bytes)
  end

  def masked_host
    source_host || begin
      return nil unless source_connection_string
      uri = URI.parse(source_connection_string)
      uri.host
    rescue URI::InvalidURIError
      nil
    end
  end

  def client_vm
    vm
  end

  def path
    "/location/#{location&.display_name}/postgres/#{target_resource&.name}/migration/#{ubid}"
  end
end
