# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      add_column :physical_slot_ready_id, :uuid
    end

    run <<~SQL
      UPDATE postgres_server AS ps
      SET physical_slot_ready_id = rep.id
      FROM postgres_server AS rep
      WHERE ps.physical_slot_ready
        AND rep.resource_id = ps.resource_id
        AND rep.is_representative
    SQL

    alter_table(:postgres_server) do
      drop_column :physical_slot_ready
    end
  end

  down do
    alter_table(:postgres_server) do
      add_column :physical_slot_ready, :boolean, null: false, default: false
      drop_column :physical_slot_ready_id
    end
  end
end
