# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_custom_label) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :installation_id, :github_installation, type: :uuid, null: false
      column :label, :text, null: false
      column :alias_for, :text, null: false
      column :concurrent_runner_count_limit, :integer, null: true
      column :allocated_runner_count, :integer, null: false, default: 0

      unique [:installation_id, :label]
      constraint(:allocated_runner_count_limit) { allocated_runner_count <= concurrent_runner_count_limit }
    end
  end
end
