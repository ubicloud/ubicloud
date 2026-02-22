# frozen_string_literal: true

Sequel.migration do
  up do
    # Set version to "v1" for existing records that have null version
    from(:machine_image).where(version: nil).update(version: "v1")

    alter_table(:machine_image) do
      # Make version required with a default
      set_column_not_null :version
      set_column_default :version, "v1"

      # Add active flag - one version per name group is active
      add_column :active, TrueClass, null: false, default: true

      # Change unique constraint: allow multiple versions per name
      drop_constraint :machine_image_project_id_location_id_name_key
      add_unique_constraint [:project_id, :location_id, :name, :version]
    end
  end

  down do
    alter_table(:machine_image) do
      drop_constraint :machine_image_project_id_location_id_name_version_key
      add_unique_constraint [:project_id, :location_id, :name]
      drop_column :active
      set_column_allow_null :version
      set_column_default :version, nil
    end
  end
end
