# frozen_string_literal: true

require "yaml"

Sequel.migration do
  up do
    affected_types = %w[
      VmVCpu VmStorage
      PostgresVCpu PostgresStorage
      PostgresStandbyVCpu PostgresStandbyStorage
      KubernetesControlPlaneVCpu KubernetesWorkerVCpu KubernetesWorkerStorage
    ].to_set
    affected_locations = %w[hetzner-fsn1 hetzner-hel1 leaseweb-wdc02].to_set

    new_rate_active_from = Time.utc(2026, 5, 1)
    cutoff = Time.utc(2026, 6, 1)
    br_type_n = 376 # UBID.to_base32_n("br")

    rates = Dir["config/billing_rates/*.yml"]
      .flat_map { |f| YAML.load_file(f, permitted_classes: [Time]) }
      .select { |r| affected_types.include?(r["resource_type"]) && affected_locations.include?(r["location"]) }

    # For each (resource_type, resource_family, location, byoc) bucket, map
    # every old rate (active_from < 2026-05-01) to the new June-1 rate
    # (active_from == 2026-05-01).
    mapping = {}
    rates.group_by { |r| [r["resource_type"], r["resource_family"], r["location"], r["byoc"]] }.each_value do |group|
      new_rate = group.find { |r| r["active_from"] == new_rate_active_from }
      next unless new_rate

      group.each do |r|
        mapping[r["id"]] = new_rate["id"] if r["active_from"] < new_rate_active_from
      end
    end

    mapping.each do |old_id, new_id|
      run <<~SQL
        INSERT INTO billing_record (id, project_id, resource_id, resource_name, span, amount, billing_rate_id, resource_tags)
        SELECT gen_random_ubid_uuid(#{br_type_n}),
               project_id, resource_id, resource_name,
               tstzrange('#{cutoff.iso8601}'::timestamptz, NULL),
               amount, '#{new_id}'::uuid, resource_tags
        FROM billing_record
        WHERE billing_rate_id = '#{old_id}'::uuid AND upper(span) IS NULL
      SQL

      run <<~SQL
        UPDATE billing_record
        SET span = tstzrange(lower(span), '#{cutoff.iso8601}'::timestamptz)
        WHERE billing_rate_id = '#{old_id}'::uuid AND upper(span) IS NULL
      SQL
    end
  end

  down do
    nil
  end
end
