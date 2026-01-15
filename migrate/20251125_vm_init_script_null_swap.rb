# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_init_script) do
      set_column_allow_null :script
      set_column_not_null :init_script
    end
  end
end
