# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:billing_record) do
      drop_constraint(:billing_record_resource_id_billing_rate_id_span_excl)
    end
  end

  down do
    alter_table(:billing_record) do
      add_exclusion_constraint([[:resource_id, "="], [:billing_rate_id, "="], [:span, "&&"]])
    end
  end
end
