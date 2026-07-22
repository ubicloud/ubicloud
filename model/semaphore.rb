# frozen_string_literal: true

require_relative "../model"

class Semaphore < Sequel::Model
  plugin ResourceMethods

  def self.incr(id, name, wake: true)
    case name
    when Symbol
      name = name.to_s
    when String
      # nothing
    else
      raise "invalid name given to Semaphore.incr: #{name.inspect}"
    end

    if wake
      with(:updated_strand,
        Strand
          .where(id:)
          .returning(:id)
          .with_sql(:update_sql, schedule: Strand::SCHEDULE_NO_LATER_THAN_NOW))
        .insert([:id, :strand_id, :name],
          DB[:updated_strand].select(Sequel[:gen_timestamp_ubid_uuid].function(820), :id, name))
    else
      insert([:id, :strand_id, :name],
        Strand.where(id:).select(Sequel[:gen_timestamp_ubid_uuid].function(820), :id, name))
    end
  end

  def self.set_at(id)
    Time.at((UBID.from_uuidish(id).to_i >> 80)/1000r).utc
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
#  id        | uuid | PRIMARY KEY
#  strand_id | uuid | NOT NULL
#  name      | text | NOT NULL
# Indexes:
#  semaphore_pkey            | PRIMARY KEY btree (id)
#  semaphore_strand_id_index | btree (strand_id)
# Foreign key constraints:
#  semaphore_strand_id_fkey | (strand_id) REFERENCES strand(id)
