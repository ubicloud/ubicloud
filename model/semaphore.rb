# frozen_string_literal: true

require_relative "../model"

class Semaphore < Sequel::Model
  plugin ResourceMethods

  def self.incr(id, name, request_ids = nil)
    case name
    when Symbol
      name = name.to_s
    when String
      # nothing
    else
      raise "invalid name given to Semaphore.incr: #{name.inspect}"
    end

    if request_ids.is_a? String
      request_ids = [request_ids]
    end

    with(:updated_strand,
      Strand
        .where(id:)
        .returning(:id)
        .with_sql(:update_sql, schedule: Sequel::CURRENT_TIMESTAMP))
      .insert([:id, :strand_id, :name, :request_ids],
        DB[:updated_strand].select(Sequel[:gen_timestamp_ubid_uuid].function(820), :id, name, request_ids))
  end
end

# Table: semaphore
# Columns:
#  id          | uuid   | PRIMARY KEY
#  strand_id   | uuid   | NOT NULL
#  name        | text   | NOT NULL
#  request_ids | text[] |
# Indexes:
#  semaphore_pkey              | PRIMARY KEY btree (id)
#  semaphore_request_ids_index | btree (request_ids)
#  semaphore_strand_id_index   | btree (strand_id)
# Foreign key constraints:
#  semaphore_strand_id_fkey | (strand_id) REFERENCES strand(id)
