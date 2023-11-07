# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:firewall_rule) do
      column :id, :uuid, primary_key: true, default: nil
      column :ip, :cidr
      foreign_key :private_subnet_id, :private_subnet, null: false, type: :uuid
    end
  end
end
