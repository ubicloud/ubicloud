# frozen_string_literal: true

Sequel.migration do
  create_enum(:quota_period, %w[one_time daily monthly])

  change do
    create_table(:free_quota) do
      column :project_id, :uuid, null: false
      column :quota_id, :uuid, null: false
      column :period, :quota_period, null: false, default: "one_time"
      column :amount, :integer, null: false, default: 0
      column :last_refreshed_at, :timestamp, null: false, default: 0
      primary_key [:project_id, :quota_id]
    end
  end
end
