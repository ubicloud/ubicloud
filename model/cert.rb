#  frozen_string_literal: true

require_relative "../model"

class Cert < Sequel::Model
  one_through_one :load_balancer, join_table: :certs_load_balancers, left_key: :cert_id, right_key: :load_balancer_id
  one_to_one :certs_load_balancers, key: :cert_id, class: CertsLoadBalancers
  one_to_one :strand, key: :id

  plugin :association_dependencies, certs_load_balancers: :destroy

  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :account_key
    enc.column :csr_key
  end

  def self.redacted_columns
    super + [:cert]
  end
end
