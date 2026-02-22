# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:machine_image) do
      add_column :arch, String, null: false, default: "x64"
    end
  end

  down do
    alter_table(:machine_image) do
      drop_column :arch
    end
  end
end
