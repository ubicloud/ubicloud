# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_installation_vcpu_usage) do
      foreign_key :installation_id, :github_installation, type: :uuid, null: false, on_delete: :cascade
      column :provider, :text, null: false
      column :arch, :arch, null: false
      Integer :used_vcpus, null: false
      primary_key [:installation_id, :provider, :arch]
      constraint(:provider_check, provider: %w[metal aws])
      constraint(:used_vcpus_not_negative) { used_vcpus >= 0 }
    end
  end
end
