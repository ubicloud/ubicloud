# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_host) do
      add_column :family, String, collate: '"C"'
    end

    run "UPDATE vm_host SET family = 'standard'"

    alter_table(:vm_host) do
      set_column_not_null :family
    end
  end

  down do
    alter_table(:vm_host) do
      drop_column :family
    end
  end
end
