# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic) do
      add_column :rekey_phase, :text, null: false, default: "idle"
      add_constraint(:rekey_phase_check) { Sequel.lit("rekey_phase IN ('idle', 'inbound', 'outbound', 'old_drop')") }
      add_foreign_key :rekey_coordinator_id, :private_subnet, type: :uuid
    end
  end
end
