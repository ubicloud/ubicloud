# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:machine_image_version_metal) do
      drop_constraint :size_set_if_enabled
      drop_column :enabled
    end
  end

  down do
    alter_table(:machine_image_version_metal) do
      add_column :enabled, :boolean, null: false, default: false
      add_constraint(:size_set_if_enabled, "NOT enabled OR archive_size_mib IS NOT NULL")
    end

    run <<~SQL
      UPDATE machine_image_version_metal SET enabled = TRUE WHERE status = 'ready'
    SQL
  end
end
