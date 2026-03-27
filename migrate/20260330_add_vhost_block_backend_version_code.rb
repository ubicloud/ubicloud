# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vhost_block_backend) do
      add_column :version_code, :integer
      add_unique_constraint [:vm_host_id, :version_code]
    end

    run <<~SQL
      UPDATE vhost_block_backend
      SET version_code = (
        SELECT
          parts[1]::integer * 10000 +
          parts[2]::integer * 100   +
          parts[3]::integer
        FROM (
          SELECT regexp_split_to_array(
            regexp_replace(version, '^v', ''),
            '[.-]'
          ) AS parts
        ) t
      );
    SQL

    alter_table(:vhost_block_backend) do
      set_column_not_null :version_code
    end
  end

  down do
    alter_table(:vhost_block_backend) do
      drop_column :version_code
    end
  end
end
