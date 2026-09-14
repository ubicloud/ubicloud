# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_runner_demand_stat) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(474)") # et ubid type (internal-only)
      column :label, :text, null: false
      column :arch, :arch, default: "x64", null: false
      column :ewma_rate, :float, null: false, default: 0
      column :ewma_hold_time, :float, null: false, default: 0
      column :last_arrival_at, :timestamptz
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique [:label, :arch]
    end
  end
end
