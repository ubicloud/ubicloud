# frozen_string_literal: true

require_relative "../model"

class StorageDevice < Sequel::Model
  include ResourceMethods

  many_to_one :vm_host

  def self.ubid_type
    UBID::TYPE_ETC
  end
end
