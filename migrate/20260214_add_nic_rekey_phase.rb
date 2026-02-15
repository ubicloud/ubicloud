# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:nic_rekey_phase, %w[idle inbound outbound old_drop])
    alter_table(:nic) do
      add_column :rekey_phase, :nic_rekey_phase, null: false, default: "idle"
      add_foreign_key :rekey_coordinator_id, :private_subnet, type: :uuid
    end
  end
end
