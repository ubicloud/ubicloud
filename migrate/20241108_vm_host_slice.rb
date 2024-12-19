# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:vm_host_slice_type, %w[dedicated shared])

    create_table(:vm_host_slice) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :enabled, :bool, null: false, default: false
      column :type, :vm_host_slice_type, default: "dedicated", null: false
      column :allowed_cpus, :text, null: false
      column :cores, Integer, null: false
      column :total_cpu_percent, Integer, null: false
      column :used_cpu_percent, Integer, null: false
      column :total_memory_1g, Integer, null: false
      column :used_memory_1g, Integer, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :vm_host_id, :vm_host, type: :uuid

      # Enforce the CPU and memory calculation logic
      constraint(:cores_not_negative) { cores >= 0 }
      constraint(:used_cpu_not_negative) { used_cpu_percent >= 0 }
      constraint(:cpu_allocation_limit) { used_cpu_percent <= total_cpu_percent }
      constraint(:used_memory_not_negative) { used_memory_1g >= 0 }
      constraint(:memory_allocation_limit) { used_memory_1g <= total_memory_1g }
    end
  end
end
