# frozen_string_literal: true

require_relative "../model"

class Address < Sequel::Model
  one_to_many :assigned_vm_addresses, key: :address_id, class: :AssignedVmAddress
  one_to_many :assigned_host_addresses, key: :address_id, class: :AssignedHostAddress

  include ResourceMethods
end
