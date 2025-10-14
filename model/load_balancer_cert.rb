#  frozen_string_literal: true

require_relative "../model"

class LoadBalancerCert < Sequel::Model(:certs_load_balancers)
  many_to_one :cert

  def before_destroy
    cert.incr_destroy
    super
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
