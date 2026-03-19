# frozen_string_literal: true

require_relative "../../model"

class PostgresMigrationDatabase < Sequel::Model
  many_to_one :postgres_migration

  plugin ResourceMethods

  def display_size
    return "Unknown" unless size_bytes
    if size_bytes >= 1024 * 1024 * 1024
      "#{(size_bytes.to_f / (1024 * 1024 * 1024)).round(1)} GB"
    elsif size_bytes >= 1024 * 1024
      "#{(size_bytes.to_f / (1024 * 1024)).round(1)} MB"
    else
      "#{(size_bytes.to_f / 1024).round(1)} KB"
    end
  end
end
