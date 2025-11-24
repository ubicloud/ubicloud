# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_init_script) do
      add_column :init_script, String
    end
  end
end
