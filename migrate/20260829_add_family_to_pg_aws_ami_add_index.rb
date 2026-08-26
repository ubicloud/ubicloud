# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :pg_aws_ami, [:aws_location_name, :pg_version, :arch, :family], name: :pg_aws_ami_aws_location_name_pg_version_arch_family_index, unique: true, concurrently: true
  end
end
