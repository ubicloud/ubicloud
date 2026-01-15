# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_custom_label) do
      # UBID.to_base32_n("gc") => 524
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(524)")
      foreign_key :installation_id, :github_installation, type: :uuid, null: false
      column :name, :text, null: false
      column :alias_for, :text, null: false
      column :concurrent_runner_count_limit, :integer, null: true
      column :allocated_runner_count, :integer, null: false, default: 0

      unique [:installation_id, :name]
      constraint(:allocated_runner_count_limit) { allocated_runner_count <= concurrent_runner_count_limit }
      constraint(:concurrent_runner_count_limit_positive) { concurrent_runner_count_limit > 0 }
    end
  end
end
