# frozen_string_literal: true

require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :vm_private_subnet, key: :vm_id

  include SemaphoreMethods
  semaphore :destroy
end
