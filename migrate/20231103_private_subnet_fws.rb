# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:firewall_type, %w[ingress egress])
    create_table(:firewall_rule) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :type, :firewall_type, null: false, default: "ingress"
      column :start_ip4, :inet, null: false
      column :end_ip4, :inet, null: false
      foreign_key :private_subnet_id, :private_subnet, null: false, type: :uuid
    end
  end
end
