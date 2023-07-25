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
