# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:dns_record) do
      set_column_not_null :dns_zone_id
    end
  end
end
