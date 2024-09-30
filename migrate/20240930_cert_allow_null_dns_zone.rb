# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:cert) do
      set_column_allow_null :dns_zone_id
    end
  end
end
