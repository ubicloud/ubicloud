# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_host) do
      add_column :family, String, collate: '"C"', default: "standard", null: false
      set_column_default :family, nil
    end
  end

  down do
    alter_table(:vm_host) do
      drop_column :family
    end
  end
end
