# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_private_subnet) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :vm_id, :vm, type: :uuid, null: false
      column :private_subnet, :cidr, null: false
    end
  end
end
