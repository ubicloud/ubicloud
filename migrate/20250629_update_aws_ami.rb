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
      INSERT INTO pg_aws_ami (id, aws_location_name, aws_ami_id, pg_version, arch) VALUES
        ('69cf6b3f-bdcb-4888-9c18-9c491a6f45ac', 'us-west-2', 'ami-044e47d7870b2f46f', '16', 'arm64'),
        ('cffe3a4e-e041-4072-9162-bb6e4b91b542', 'us-west-2', 'ami-035d4adf04d2f0bbd', '17', 'arm64')
    SQL

    alter_table(:pg_aws_ami) do
      set_column_not_null :arch
    end
  end

  down do
    run <<~SQL
      DELETE FROM pg_aws_ami WHERE arch = 'arm64';
    SQL

    alter_table(:pg_aws_ami) do
      drop_column :arch
      drop_index [:aws_location_name, :pg_version, :arch], concurrently: true
      add_index [:aws_location_name, :pg_version], unique: true, concurrently: true
    end
  end
end
