# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic) do
      add_column :rekey_payload, :jsonb
    end
  end
end
