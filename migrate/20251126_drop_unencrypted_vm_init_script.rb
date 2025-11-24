# frozen_string_literal: true

Sequel.migration do
  revert do
    alter_table(:vm_init_script) do
      add_column :script, String, size: 2000
    end
  end
end
