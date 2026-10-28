# frozen_string_literal: true

# Billing rates key discounts and credits by <family> for VMs and by
# standard-<family> for Postgres, hence both forms in rate_families.
Sequel.migration do
  families = {
    "c4a-standard" => "c4a-standard-lssd",
    "c4a-highmem" => "c4a-highmem-lssd",
    "c4-standard" => "c4-standard-lssd",
    "c4-highmem" => "c4-highmem-lssd",
    "c4d-standard" => "c4d-standard-lssd",
    "c4d-highmem" => "c4d-highmem-lssd",
    "c3-standard" => "c3-standard-lssd",
    "c3d-standard" => "c3d-standard-lssd",
    "c3d-highmem" => "c3d-highmem-lssd",
    "z3-standardlssd" => "z3-highmem-standardlssd",
    "z3-highlssd" => "z3-highmem-highlssd",
  }
  rate_scoped_tables = [:resource_discount, :resource_credit]

  rename = ->(db, mapping) do
    mapping.each do |from, to|
      prefix_pattern = "^#{Regexp.escape(from)}-"
      size_pattern = /#{prefix_pattern}\d+$/
      rate_families = {from => to, "standard-#{from}" => "standard-#{to}"}

      db.from(:vm).where(family: from).update(family: to)

      rate_scoped_tables.each do |table|
        db.from(table)
          .where(resource_family: rate_families.keys)
          .update(resource_family: Sequel.case(rate_families, :resource_family, :resource_family))
      end

      db.from(:postgres_resource)
        .where(target_vm_size: size_pattern)
        .update(target_vm_size: Sequel.function(:regexp_replace, :target_vm_size, prefix_pattern, "#{to}-"))

      from_flag, to_flag = [from, to].map { "enable_#{it.tr("-", "_")}" }
      flags = Sequel.pg_jsonb_op(:feature_flags)
      db.from(:project)
        .where(flags.has_key?(from_flag))
        .update(feature_flags: (flags - from_flag).concat(Sequel.function(:jsonb_build_object, Sequel.cast(to_flag, :text), flags[from_flag])))

      values = Sequel.pg_jsonb_op(:model_values)
      db.from(:deleted_record)
        .where(Sequel[:model_name] => "PostgresResource", values.get_text("target_vm_size") => size_pattern)
        .update(model_values: values.concat(Sequel.function(:jsonb_build_object, Sequel.cast("target_vm_size", :text),
          Sequel.function(:regexp_replace, values.get_text("target_vm_size"), prefix_pattern, "#{to}-"))))
    end
  end

  up { rename.call(self, families) }
  down { rename.call(self, families.invert) }
end
