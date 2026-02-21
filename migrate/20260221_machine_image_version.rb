# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:machine_image) do
      add_column :version, String
    end
  end

  down do
    alter_table(:machine_image) do
      drop_column :version
    end
  end
end
