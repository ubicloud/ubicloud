# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :local_vetho_ip, :text, collate: '"C"'
    end
    create_table :address do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :cidr, :cidr, null: false, unique: true
      column :is_failover_ip, :boolean, null: false, default: false
      foreign_key :routed_to_host_id, :vm_host, type: :uuid, null: false
    end
    create_table :assigned_vm_address do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :ip, :cidr, null: false, unique: true
      foreign_key :address_id, :address, type: :uuid, null: false
      foreign_key :dst_vm_id, :vm, type: :uuid, null: false
    end
    create_table :assigned_host_address do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :ip, :cidr, null: false, unique: true
      foreign_key :address_id, :address, type: :uuid, null: false
      foreign_key :host_id, :vm_host, type: :uuid, null: false
    end
  end
end
