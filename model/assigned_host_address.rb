# frozen_string_literal: true

require_relative "../model"

class AssignedHostAddress < Sequel::Model
  many_to_one :vm_host, key: :host_id
  many_to_one :address, key: :address_id

  include ResourceMethods
end
