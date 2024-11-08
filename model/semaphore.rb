# frozen_string_literal: true

require_relative "../model"

class Semaphore < Sequel::Model
  include ResourceMethods

  def self.incr(strand_id, name)
    DB.transaction do
      Strand.dataset.where(id: strand_id).update(schedule: Sequel::CURRENT_TIMESTAMP)
      Semaphore.create_with_id(strand_id: strand_id, name: name)
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
