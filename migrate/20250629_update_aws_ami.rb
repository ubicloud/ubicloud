# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:pg_aws_ami) do
      add_column :arch, :text
      drop_index [:aws_location_name, :pg_version], concurrently: true
      add_index [:aws_location_name, :pg_version, :arch], unique: true, concurrently: true
    end

    run <<~SQL
      UPDATE pg_aws_ami SET arch = 'x64';
    SQL

    alter_table(:pg_aws_ami) do
      set_column_not_null :arch
    end
  end

  down do
    alter_table(:pg_aws_ami) do
      drop_column :arch
      drop_index [:aws_location_name, :pg_version, :arch], concurrently: true
      add_index [:aws_location_name, :pg_version], unique: true, concurrently: true
    end
  end
end
