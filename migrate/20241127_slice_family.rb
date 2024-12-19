# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host_slice) do
      add_column :family, :text, collate: '"C"'
    end
  end
end
