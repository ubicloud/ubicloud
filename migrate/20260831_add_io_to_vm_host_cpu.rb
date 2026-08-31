# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host_cpu) do
      add_column :io, :boolean
    end
  end
end
