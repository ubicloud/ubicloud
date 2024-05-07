# frozen_string_literal: true

require_relative "../model"

class PciDevice < Sequel::Model
  include ResourceMethods

  many_to_one :vm_host
  many_to_one :vm

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def is_gpu
    ["0300", "0302"].include? device_class
  end
end
