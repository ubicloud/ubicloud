# frozen_string_literal: true

require "json"

# Backfill managed roles from the legacy cert_auth_users list so existing cert
# users show up in the Managed Roles UI and gain pgbouncer (back-leg) support.
# The cert_auth_users column and its endpoints are kept; configure reads both
# sources (deduplicated). Only names that are valid, non-reserved role
# identifiers are migrated, so a managed role never carries a name that could be
# unsafe to interpolate into reconcile SQL.
Sequel.migration do
  up do
    reserved = %w[postgres ubi ubi_replication ubi_monitoring ubi_admin pgbouncer]
    managed_role = from(:postgres_managed_role)

    from(:postgres_resource).select_map([:id, :cert_auth_users]).each do |resource_id, cert_auth_users|
      cert_auth_users = JSON.parse(cert_auth_users) if cert_auth_users.is_a?(String)
      Array(cert_auth_users).each do |name|
        next unless name.is_a?(String) && name.match?(/\A[a-z_][a-z0-9_]*\z/) && name.length <= 63
        next if reserved.include?(name) || name.start_with?("pg_")
        next if managed_role.where(postgres_resource_id: resource_id, name:).count > 0

        # UBID.to_base32_n("mr") => 664
        managed_role.insert(
          id: Sequel.function(:gen_random_ubid_uuid, 664),
          postgres_resource_id: resource_id,
          name:,
          auth_type: "cert",
          state: "active",
        )
      end
    end
  end

  down do
    # Managed roles created from cert_auth_users are kept.
  end
end
