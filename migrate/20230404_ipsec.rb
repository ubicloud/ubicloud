# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:ipsec_tunnel) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :src_vm_id, :vm, type: :uuid, null: false
      foreign_key :dst_vm_id, :vm, type: :uuid, null: false
    end
  end
end
