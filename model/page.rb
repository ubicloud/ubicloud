# frozen_string_literal: true

require_relative "../model"

class Page < Sequel::Model
  dataset_module do
    def active
      where(resolved_at: nil)
    end
  end

  include SemaphoreMethods
  include ResourceMethods
  semaphore :resolve

  def self.ubid_type
    UBID::TYPE_PAGE
  end

  def resolve
    update(resolved_at: Time.now)
  end
end
