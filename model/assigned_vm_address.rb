# frozen_string_literal: true

require_relative "../model"

class AssignedVmAddress < Sequel::Model
  one_to_one :vm, key: :dst_vm_id
  many_to_one :address, key: :address_id
  one_to_one :active_billing_record, class: :BillingRecord, key: :resource_id, conditions: {Sequel.function(:upper, :span) => nil}

  include ResourceMethods
end
