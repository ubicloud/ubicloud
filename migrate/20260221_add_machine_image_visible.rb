# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:machine_image) do
      add_column :visible, TrueClass, null: false, default: false
    end
  end

  down do
    alter_table(:machine_image) do
      drop_column :visible
    end
  end
end
