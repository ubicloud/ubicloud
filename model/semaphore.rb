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

    values_ds = Strand.where(id:)
    insert_ds = self
    if wake
      insert_ds = with(:updated_strand,
        values_ds
          .returning(:id)
          .with_sql(:update_sql, schedule: Strand::SCHEDULE_NO_LATER_THAN_NOW))
      values_ds = DB[:updated_strand]
    end
    insert_ds.insert([:id, :strand_id, :name],
      values_ds.select(Sequel[:gen_timestamp_ubid_uuid].function(820), :id, name))
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
