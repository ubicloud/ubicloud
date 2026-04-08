# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:gcp_vpc) do
      column :id, :uuid, primary_key: true, default: nil
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      column :name, :text, null: false
      column :firewall_policy_name, :text
      column :network_self_link, :text
      unique [:project_id, :location_id]
    end

    alter_table(:private_subnet) do
      add_foreign_key :gcp_vpc_id, :gcp_vpc, type: :uuid, null: true
    end
  end

  down do
    alter_table(:private_subnet) do
      drop_foreign_key :gcp_vpc_id
    end
    drop_table(:gcp_vpc)
  end
end
