# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :os_version, :text, collate: '"C"', null: true
    end
  end
end
