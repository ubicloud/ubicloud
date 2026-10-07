#  frozen_string_literal: true

require_relative "../model"

class Cert < Sequel::Model
  one_to_one :load_balancer_cert, read_only: true
  one_to_one :strand, key: :id

  plugin :association_dependencies, load_balancer_cert: :destroy

  plugin ResourceMethods, redacted_columns: :cert, encrypted_columns: [:account_key, :csr_key]
  plugin SemaphoreMethods, :destroy, :restarted

  dataset_module do
    exclude :with_cert, cert: nil

    current_timestamp = Sequel::CURRENT_TIMESTAMP
    days = [15, 30, 60, 90].to_h { [it, Sequel.cast("#{it} days", :interval)] }
    expires_at = Sequel[:expires_at]

    where(:fresh, Sequel.case(
      {
        {expires_at: nil} => current_timestamp - days[60] < :created_at,
        (expires_at - :created_at > days[60]) => expires_at - days[30] > current_timestamp,
      },
      expires_at - days[15] > current_timestamp,
    ))

    where(:active, Sequel.case(
      {{expires_at: nil} => current_timestamp - days[90] < :created_at},
      expires_at > current_timestamp,
    ))

    reverse(:by_most_recent, :created_at)
  end

  def hostnames
    private_hostname ? [hostname, private_hostname] : [hostname]
  end

  def before_save
    self.expires_at ||= Util.cert_expires_at(cert) if cert
    super
  end
end

# Table: cert
# Columns:
#  id               | uuid                        | PRIMARY KEY
#  hostname         | text                        | NOT NULL
#  dns_zone_id      | uuid                        |
#  created_at       | timestamp without time zone | NOT NULL DEFAULT now()
#  cert             | text                        |
#  account_key      | text                        |
#  kid              | text                        |
#  order_url        | text                        |
#  csr_key          | text                        |
#  private_hostname | text                        |
#  expires_at       | timestamp with time zone    |
# Indexes:
#  cert_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  cert_dns_zone_id_fkey | (dns_zone_id) REFERENCES dns_zone(id)
# Referenced By:
#  certs_load_balancers         | certs_load_balancers_cert_id_fkey         | (cert_id) REFERENCES cert(id)
#  presigned_load_balancer_cert | presigned_load_balancer_cert_cert_id_fkey | (cert_id) REFERENCES cert(id)
#  presigned_postgres_cert      | presigned_postgres_cert_cert_id_fkey      | (cert_id) REFERENCES cert(id)
