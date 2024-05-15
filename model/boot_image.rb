# frozen_string_literal: true

require_relative "../model"

class BootImage < Sequel::Model
  many_to_one :vm_host, key: :vm_host_id, class: :VmHost
  one_to_many :vm_storage_volumes, key: :boot_image_id, class: :VmStorageVolume

  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def path
    version ?
        "/var/storage/images/#{name}-#{version}.raw" :
        "/var/storage/images/#{name}.raw"
  end
end
