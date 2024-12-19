# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :accepts_slices, :boolean, null: false, default: false
    end

    run "UPDATE vm_host SET accepts_slices = true WHERE os_version = 'ubuntu-24.04';"
  end
end
