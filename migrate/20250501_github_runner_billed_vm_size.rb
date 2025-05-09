# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      add_column :billed_vm_size, String, collate: '"C"', null: true
    end
  end
end
