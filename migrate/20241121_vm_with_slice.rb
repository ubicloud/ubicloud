# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_foreign_key :vm_host_slice_id, :vm_host_slice, type: :uuid
    end
  end
end
