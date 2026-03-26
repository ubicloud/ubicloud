# frozen_string_literal: true

require_relative "../model"

class Semaphore < Sequel::Model
  plugin ResourceMethods

  def self.incr(id, name, request_id = nil)
    case name
    when Symbol
      name = name.to_s
    when String
      # nothing
    else
      raise "invalid name given to Semaphore.incr: #{name.inspect}"
    end

    with(:updated_strand,
      Strand
        .where(id:)
        .returning(:id)
        .with_sql(:update_sql, schedule: Sequel::CURRENT_TIMESTAMP))
      .insert([:id, :strand_id, :name, :request_id],
        DB[:updated_strand].select(Sequel[:gen_timestamp_ubid_uuid].function(820), :id, name, request_id))
  end

  def self.relay(from_strand_id, name, to_strand_ids, to_name = nil)
    to_name = (to_name || name).to_s
    name = name.to_s
    source = where(strand_id: from_strand_id, name:)
    to_strand_ids.each do |target_id|
      DB[:semaphore].insert(
        [:id, :strand_id, :name, :request_id],
        source.select(Sequel[:gen_timestamp_ubid_uuid].function(820), target_id, to_name, :request_id)
      )
    end
    source.destroy
  end

  def self.set_at(id)
    Time.at((UBID.from_uuidish(id).to_i >> 80) / 1000.0).utc
  end

  def set_at
    Semaphore.set_at(id)
  end

  def inspect_values_hash
    hash = super
    hash[:set_at] = set_at.strftime("%F %T")
    hash
  end
end

# Table: semaphore
# Columns:
#  id         | uuid | PRIMARY KEY
#  strand_id  | uuid | NOT NULL
#  name       | text | NOT NULL
#  request_id | text |
# Indexes:
#  semaphore_pkey             | PRIMARY KEY btree (id)
#  semaphore_request_id_index | btree (request_id)
#  semaphore_strand_id_index  | btree (strand_id)
# Foreign key constraints:
#  semaphore_strand_id_fkey | (strand_id) REFERENCES strand(id)
