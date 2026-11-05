#  frozen_string_literal: true

require_relative "../model"

class Cert < Sequel::Model
  one_to_one :load_balancer_cert, read_only: true
  many_to_one :acme_provider
  one_to_one :strand, key: :id

  plugin :association_dependencies, load_balancer_cert: :destroy

  plugin ResourceMethods, redacted_columns: :cert, encrypted_columns: [:account_key, :csr_key]
  plugin SemaphoreMethods, :destroy, :restarted

  dataset_module do
    exclude :with_cert, cert: nil

    current_timestamp = Sequel::CURRENT_TIMESTAMP
    days = [15, 30, 60, 90].to_h { [it, Sequel.cast("#{it} days", :interval)] }
    expires_at = Sequel[:expires_at]

    # Certificates that do not need replacing yet; a consumer replaces
    # its certificate when none is fresh. A reissue request makes a
    # certificate stale at once, so it is replaced early, and it keeps
    # serving until then.
    where(:fresh, Sequel.&(
      Sequel.case(
        {
          {expires_at: nil} => current_timestamp - days[60] < :created_at,
          (expires_at - :created_at > days[60]) => expires_at - days[30] > current_timestamp,
        },
        expires_at - days[15] > current_timestamp,
      ),
      {reissue_requested_at: nil},
    ))

    where(:active, Sequel.case(
      {{expires_at: nil} => current_timestamp - days[90] < :created_at},
      expires_at > current_timestamp,
    ))

    reverse(:by_most_recent, :created_at)
  end

  # Programs that keep their certificate's id in a current_cert_id frame
  # key and replace the certificate when refresh_certificates is set.
  CURRENT_CERT_HOLDERS = ["Postgres::PostgresResourceNexus", "Minio::MinioClusterNexus", "Minio::MinioServerNexus"].freeze

  # Whether the certificate with this id, if there is one, has a reissue
  # request.
  def self.reissue_requested?(id)
    !where(id:).exclude(reissue_requested_at: nil).empty?
  end

  # Ask every holder of these certificates to replace them now, rather
  # than at its next periodic check, which can be a day or a week away.
  def self.request_replacement(ids)
    # refresh_cert makes a load balancer create a certificate even when
    # certificates are turned off for it, so wake only those that use them.
    holding = DB[:certs_load_balancers].where(cert_id: ids).select(:load_balancer_id)
    LoadBalancer.incr_refresh_cert(LoadBalancer.where(id: holding, cert_enabled: true).select(:id))
    frames = DB.from(Sequel.function(:jsonb_array_elements, Sequel[:strand][:stack]).as(:frame))
      .where(Sequel.cast(Sequel.pg_jsonb_op(:frame).get_text("current_cert_id"), :uuid) => ids)
    Semaphore.incr(Strand.where(prog: CURRENT_CERT_HOLDERS).where(frames.exists).select(:id), :refresh_certificates)
    Prog::Vnet::MaintainPresignedLoadBalancerCerts.schedule_strand
    Prog::Vnet::MaintainPresignedPostgresCerts.schedule_strand
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
#  id                   | uuid                        | PRIMARY KEY
#  hostname             | text                        | NOT NULL
#  dns_zone_id          | uuid                        |
#  created_at           | timestamp without time zone | NOT NULL DEFAULT now()
#  cert                 | text                        |
#  account_key          | text                        |
#  kid                  | text                        |
#  order_url            | text                        |
#  csr_key              | text                        |
#  private_hostname     | text                        |
#  expires_at           | timestamp with time zone    |
#  acme_provider_id     | uuid                        |
#  reissue_requested_at | timestamp with time zone    |
# Indexes:
#  cert_pkey                   | PRIMARY KEY btree (id)
#  cert_acme_provider_id_index | btree (acme_provider_id) WHERE acme_provider_id IS NOT NULL
# Foreign key constraints:
#  cert_acme_provider_id_fkey | (acme_provider_id) REFERENCES acme_provider(id)
#  cert_dns_zone_id_fkey      | (dns_zone_id) REFERENCES dns_zone(id)
# Referenced By:
#  certs_load_balancers         | certs_load_balancers_cert_id_fkey         | (cert_id) REFERENCES cert(id)
#  presigned_load_balancer_cert | presigned_load_balancer_cert_cert_id_fkey | (cert_id) REFERENCES cert(id)
#  presigned_postgres_cert      | presigned_postgres_cert_cert_id_fkey      | (cert_id) REFERENCES cert(id)
