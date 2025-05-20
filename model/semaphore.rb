# frozen_string_literal: true

require_relative "../model"

class Semaphore < Sequel::Model
  plugin ResourceMethods

  def self.incr(strand_id, name)
    DB.transaction do
      if Strand.where(id: strand_id).update(schedule: Sequel::CURRENT_TIMESTAMP) == 1
        create(strand_id:, name:)
      end
    end
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
