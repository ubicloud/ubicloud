# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :data_center, :text, collate: '"C"'
    end
  end
end
