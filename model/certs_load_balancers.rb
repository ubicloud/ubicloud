#  frozen_string_literal: true

require_relative "../model"

class CertsLoadBalancers < Sequel::Model
  many_to_one :cert
  include ResourceMethods

  def destroy
    DB.transaction do
      cert.incr_destroy
      super
    end
  end
end

# Table: certs_load_balancers
# Primary Key: (load_balancer_id, cert_id)
# Columns:
#  load_balancer_id | uuid |
#  cert_id          | uuid |
# Indexes:
#  certs_load_balancers_pkey | PRIMARY KEY btree (load_balancer_id, cert_id)
# Foreign key constraints:
#  certs_load_balancers_cert_id_fkey          | (cert_id) REFERENCES cert(id)
#  certs_load_balancers_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
