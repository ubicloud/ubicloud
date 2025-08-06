#  frozen_string_literal: true

require_relative "../model"

class Cert < Sequel::Model
  one_through_one :load_balancer, join_table: :certs_load_balancers, left_key: :cert_id, right_key: :load_balancer_id
  one_to_one :load_balancer_cert
  one_to_one :strand, key: :id

  plugin :association_dependencies, load_balancer_cert: :destroy

  plugin ResourceMethods, redacted_columns: :cert, encrypted_columns: [:account_key, :csr_key]
  plugin SemaphoreMethods, :destroy, :restarted

  dataset_module do
    exclude :with_cert, cert: nil
    where(:needing_recert, Sequel::CURRENT_TIMESTAMP - Sequel.cast("60 days", :interval) < :created_at)
    where(:active, Sequel::CURRENT_TIMESTAMP - Sequel.cast("90 days", :interval) < :created_at)
    reverse(:by_most_recent, :created_at)
  end
end

# Table: cert
# Columns:
#  id          | uuid                        | PRIMARY KEY
#  hostname    | text                        | NOT NULL
#  dns_zone_id | uuid                        |
#  created_at  | timestamp without time zone | NOT NULL DEFAULT now()
#  cert        | text                        |
#  account_key | text                        |
#  kid         | text                        |
#  order_url   | text                        |
#  csr_key     | text                        |
# Indexes:
#  cert_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  cert_dns_zone_id_fkey | (dns_zone_id) REFERENCES dns_zone(id)
# Referenced By:
#  certs_load_balancers | certs_load_balancers_cert_id_fkey | (cert_id) REFERENCES cert(id)
