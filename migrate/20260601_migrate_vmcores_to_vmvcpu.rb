# frozen_string_literal: true

require "yaml"

Sequel.migration do
  up do
    cutoff = Time.utc(2026, 6, 1)
    br_type_n = 376 # UBID.to_base32_n("br")

    relevant_types = %w[VmCores VmVCpu].to_set
    rates = Dir["config/billing_rates/*.yml"]
      .flat_map { |f| YAML.load_file(f, permitted_classes: [Time]) }
      .select { |r| relevant_types.include?(r["resource_type"]) }

    new_vcpu_by_key = rates
      .select { |r| r["resource_type"] == "VmVCpu" }
      .group_by { |r| [r["resource_family"], r["location"], r["byoc"]] }
      .transform_values { |group| group.max_by { |r| r["active_from"] }["id"] }

    mapping = {}
    rates.each do |r|
      next unless r["resource_type"] == "VmCores"
      new_id = new_vcpu_by_key[[r["resource_family"], r["location"], r["byoc"]]]
      next unless new_id
      mapping[r["id"]] = new_id
    end

    mapping.each do |old_id, new_id|
      run <<~SQL
        INSERT INTO billing_record (id, project_id, resource_id, resource_name, span, amount, billing_rate_id, resource_tags)
        SELECT gen_random_ubid_uuid(#{br_type_n}),
               project_id, resource_id, resource_name,
               tstzrange('#{cutoff.iso8601}'::timestamptz, NULL),
               amount * 2, '#{new_id}'::uuid, resource_tags
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
