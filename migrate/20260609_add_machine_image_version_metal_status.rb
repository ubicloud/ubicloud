# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:machine_image_version_metal) do
      add_column :status, :text
      add_constraint(:machine_image_version_metal_status_check, "status IN ('creating', 'ready', 'destroying')")
      add_constraint(:archive_size_set_if_status_ready, "status <> 'ready' OR archive_size_mib IS NOT NULL")
    end
  end
end
