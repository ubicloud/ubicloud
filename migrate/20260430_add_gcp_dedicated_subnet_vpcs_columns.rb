# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :gcp_dedicated_subnet_vpcs, :boolean, null: false, default: false
    end

    alter_table(:gcp_vpc) do
      add_foreign_key :dedicated_for_subnet_id, :private_subnet, type: :uuid, on_delete: :cascade
    end
  end
end
