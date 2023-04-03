# frozen_string_literal: true

require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :vm_private_subnet, key: :vm_id
  one_to_many :ipsec_tunnels, key: :src_vm_id

  include SemaphoreMethods
  semaphore :destroy, :refresh_mesh

  def private_subnets
    vm_private_subnet.map { _1.private_subnet }
  end
end
