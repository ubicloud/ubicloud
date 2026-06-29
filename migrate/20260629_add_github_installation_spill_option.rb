# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_installation_spill_option) do
      foreign_key :id, :github_installation, type: :uuid, null: false, primary_key: true
      column :spill_ratio, :numeric, null: false, default: 0
      column :vcpus_limit, :integer, null: false
      column :allocated_vcpus, :integer, null: false, default: 0

      constraint(:allocated_vcpus_within_limit) { allocated_vcpus <= vcpus_limit }
      constraint(:allocated_vcpus_non_negative) { allocated_vcpus >= 0 }
      constraint(:vcpus_limit_non_negative) { vcpus_limit >= 0 }
      constraint(:spill_ratio_range) { (spill_ratio >= 0) & (spill_ratio <= 1) }
    end
  end
end
