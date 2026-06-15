# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:machine_image_version_metal) do
      drop_constraint(:machine_image_version_metal_status_check)
      add_constraint(:machine_image_version_metal_status_check,
        "status IN ('creating', 'ready', 'destroying', 'failed')")
    end
  end

  down do
    alter_table(:machine_image_version_metal) do
      drop_constraint(:machine_image_version_metal_status_check)
      add_constraint(:machine_image_version_metal_status_check,
        "status IN ('creating', 'ready', 'destroying')")
    end
  end
end
