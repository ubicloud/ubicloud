# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_pool) do
      column :id, :uuid, primary_key: true, default: nil
      column :size, :integer, null: false
      column :vm_size, :text, null: false
      column :boot_image, :text, null: false
      column :location, :text, null: false
    end

    alter_table(:vm) do
      add_foreign_key :pool_id, :vm_pool, type: :uuid, null: true
    end
  end
end
