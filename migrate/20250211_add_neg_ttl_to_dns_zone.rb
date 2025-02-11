# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:dns_zone) do
      add_column :neg_ttl, Integer, default: 3600, null: false
    end
  end
end
