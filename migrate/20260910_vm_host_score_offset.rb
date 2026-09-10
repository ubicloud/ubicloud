# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :score_offset, :double, null: false, default: 0
    end
  end
end
