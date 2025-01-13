# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_host_slice) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :enabled, :bool, default: false, null: false
      column :is_shared, :bool, default: false, null: false
      column :cores, Integer, null: false
      column :total_cpu_percent, Integer, null: false
      column :used_cpu_percent, Integer, null: false
      column :total_memory_gib, Integer, null: false
      column :used_memory_gib, Integer, null: false
      column :family, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false

      # Enforce the CPU and memory calculation logic
      constraint(:cores_not_negative) { cores >= 0 }
      constraint(:used_cpu_not_negative) { used_cpu_percent >= 0 }
      constraint(:cpu_allocation_limit) { used_cpu_percent <= total_cpu_percent }
      constraint(:used_memory_not_negative) { used_memory_gib >= 0 }
      constraint(:memory_allocation_limit) { used_memory_gib <= total_memory_gib }
    end

    alter_table(:vm) do
      add_foreign_key :vm_host_slice_id, :vm_host_slice, type: :uuid
    end
  end
end
