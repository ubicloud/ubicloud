# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:pg_aws_ami) do
      add_column :family, :text, null: false, default: "ubuntu-2204"
    end

    add_index :pg_aws_ami, [:aws_location_name, :pg_version, :arch, :family], unique: true, concurrently: true
    drop_index :pg_aws_ami, [:aws_location_name, :pg_version, :arch], name: :pg_aws_ami_aws_location_name_pg_version_arch_index, unique: true, concurrently: true
  end

  down do
    add_index :pg_aws_ami, [:aws_location_name, :pg_version, :arch], name: :pg_aws_ami_aws_location_name_pg_version_arch_index, unique: true, concurrently: true
    drop_index :pg_aws_ami, [:aws_location_name, :pg_version, :arch, :family], unique: true, concurrently: true

    alter_table(:pg_aws_ami) do
      drop_column :family
    end
  end
end
