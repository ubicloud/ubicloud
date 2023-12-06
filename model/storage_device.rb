# frozen_string_literal: true

require_relative "../model"

class StorageDevice < Sequel::Model
  many_to_one :vm_host

  def self.generate_uuid
    UBID.generate(UBID::TYPE_ETC).to_uuid
  end
end
