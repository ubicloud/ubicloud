# frozen_string_literal: true

require_relative "../../model"

class PostgresLsnMonitor < Sequel::Model
  plugin :insert_conflict
end
