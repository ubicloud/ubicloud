# frozen_string_literal: true

require_relative "../../model"

class PostgresManagedRole < Sequel::Model
  many_to_one :postgres_resource
  many_to_one :project

  plugin ResourceMethods, redacted_columns: :cert, encrypted_columns: :cert_key
  include ObjectTag::Cleanup

  AUTH_TYPES = %w[password cert].freeze

  # Roles that customers must not be able to manage through this feature:
  # Ubicloud's internal roles plus PostgreSQL's reserved "pg_" prefix.
  RESERVED_NAMES = %w[postgres ubi ubi_replication ubi_monitoring ubi_admin pgbouncer].freeze

  def before_validation
    self.project_id ||= postgres_resource&.project_id
    super
  end

  def validate
    super
    validates_includes(AUTH_TYPES, :auth_type)
    if (value = name)
      validates_format(/\A[a-z_][a-z0-9_]*\z/, :name, message: "must start with a lowercase letter or underscore and contain only lowercase letters, digits, and underscores")
      validates_max_length(63, :name)
      errors.add(:name, "is a reserved role name") if RESERVED_NAMES.include?(value) || value.start_with?("pg_")
    else
      errors.add(:name, "is not present")
    end
  end

  def cert_auth?
    auth_type == "cert"
  end

  # How long an issued client certificate is valid. These certs are minted by
  # Ubicloud (not user-supplied) and re-issued on rotation; a predecessor cert
  # stays valid until expiry since there is no CRL yet.
  CERTIFICATE_DURATION = 60 * 60 * 24 * 365

  # Sign a client certificate for this role from the resource's client CA and
  # store it (with the private key encrypted at rest) for later download. The
  # common name is the role name, so the generated
  # "hostssl all <name> all cert" pg_hba rule authenticates it.
  def issue_certificate!
    issuer_cert, issuer_key = postgres_resource.client_signing_key
    cert, key = Util.create_certificate(
      subject: "/C=US/O=None/CN=#{name}",
      extensions: ["keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=clientAuth"],
      duration: CERTIFICATE_DURATION,
      issuer_cert:,
      issuer_key:,
    )
    update(cert: cert.to_pem, cert_key: key.to_pem, cert_not_after: cert.not_after)
  end

  # Downloadable PEM bundle (certificate followed by its private key), or nil
  # if no certificate has been issued yet.
  def certificate_bundle
    "#{cert}#{cert_key}" if cert && cert_key
  end
end

# Table: postgres_managed_role
# Columns:
#  id                   | uuid                     | PRIMARY KEY
#  postgres_resource_id | uuid                     | NOT NULL
#  name                 | text                     | NOT NULL
#  auth_type            | text                     | NOT NULL
#  state                | text                     | NOT NULL DEFAULT 'creating'::text
#  cert                 | text                     |
#  cert_key             | text                     |
#  cert_not_after       | timestamp with time zone |
#  last_error           | text                     |
#  created_at           | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id           | uuid                     | NOT NULL
# Indexes:
#  postgres_managed_role_pkey                  | PRIMARY KEY btree (id)
#  postgres_managed_role_resource_id_name_uidx | UNIQUE btree (postgres_resource_id, name)
#  postgres_managed_role_project_id_index      | btree (project_id)
# Check constraints:
#  postgres_managed_role_auth_type_check | (auth_type = ANY (ARRAY['password'::text, 'cert'::text]))
#  postgres_managed_role_state_check     | (state = ANY (ARRAY['creating'::text, 'active'::text, 'destroying'::text]))
# Foreign key constraints:
#  postgres_managed_role_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
#  postgres_managed_role_project_id_fkey           | (project_id) REFERENCES project(id)
