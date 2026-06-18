# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic) do
      add_column :rekey_phase, :text, null: false, default: "idle"
      add_constraint(:rekey_phase_check, rekey_phase: %w[idle inbound outbound old_drop])
      add_foreign_key :rekey_coordinator_id, :private_subnet, type: :uuid
    end

    alter_table(:private_subnet) do
      add_column :rekey_protocol, Integer, null: false, default: 1
      add_constraint(:rekey_protocol_check, rekey_protocol: [1, 2])
    end
  end
end
