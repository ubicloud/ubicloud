# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:storage_device) do
      add_column :blk_dev_serial_number, "text[]"
    end
  end

  down do
    alter_table(:storage_device) do
      drop_column :blk_dev_serial_number
    end
  end
end
