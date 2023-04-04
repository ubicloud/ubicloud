# frozen_string_literal: true

require "ulid"
require_relative "../model"

class Semaphore < Sequel::Model
  def self.incr(strand_id, name)
    DB.transaction do
      Strand.dataset.where(id: strand_id).update(schedule: Sequel::CURRENT_TIMESTAMP)
      Semaphore.create(strand_id: strand_id, name: name) do
        # Use ULIDs since semaphores have temporal locality, and there's
        # not any harm in letting date information leak from their
        # identifier.
        _1.id = ULID.generate.to_uuidish
      end
    end
  end
end
