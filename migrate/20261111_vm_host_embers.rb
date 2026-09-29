# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :accepts_embers, TrueClass, null: false, default: false
      add_column :cpu_signature, :text, collate: '"C"'
    end
  end
end
