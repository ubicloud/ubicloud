# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vhost_block_backend) do
      drop_column :version
    end
  end

  down do
    alter_table(:vhost_block_backend) do
      add_column :version, :text, collate: '"C"'
      add_unique_constraint [:vm_host_id, :version]
    end

    run <<~SQL
      UPDATE vhost_block_backend
      SET version = format(
        CASE WHEN version_code < 200 THEN 'v%s.%s-%s' ELSE 'v%s.%s.%s' END,
        version_code / 10000,
        (version_code / 100) % 100,
        version_code % 100
      );
    SQL

    alter_table(:vhost_block_backend) do
      set_column_not_null :version
    end
  end
end
