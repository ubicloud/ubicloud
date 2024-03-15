# frozen_string_literal: true

require_relative "../model"

class Loadbalancer < Sequel::Model
  one_to_one :assigned_address, key: :loadbalancer_id, class: AssignedVmAddress
  many_to_one :vm_host

  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_ETC
  end
end
