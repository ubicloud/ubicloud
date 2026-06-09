# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE machine_image_version_metal
      SET status = CASE
        WHEN enabled THEN 'ready'
        WHEN archive_size_mib IS NOT NULL THEN 'destroying'
        ELSE 'creating'
      END
      WHERE status IS NULL
    SQL

    alter_table(:machine_image_version_metal) do
      set_column_not_null :status
    end
  end

  down do
    alter_table(:machine_image_version_metal) do
      set_column_allow_null :status
    end
    # Intentionally no-op for the backfill: status is derivable from enabled
    # and archive_size_mib in any environment that ran the up step.
  end
end
