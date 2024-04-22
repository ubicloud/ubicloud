# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      set_column_not_null :storage_device_id
    end

    alter_table(:storage_device) do
      add_constraint(:available_storage_gib_non_negative) { available_storage_gib >= 0 }
      add_constraint(:available_storage_gib_less_than_or_equal_to_total) { available_storage_gib <= total_storage_gib }
    end
  end
end
