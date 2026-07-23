# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:private_subnet) do
      drop_column :rekey_protocol
    end
  end

  down do
    alter_table(:private_subnet) do
      add_column :rekey_protocol, Integer, null: false, default: 2
      add_constraint(:rekey_protocol_check, rekey_protocol: [1, 2])
    end
  end
end
