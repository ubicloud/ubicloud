# frozen_string_literal: true

Sequel.migration do
  change do
    # The warm pool of blank embers, one per location. Blanks are held by the
    # location rather than by a host so that the target does not move every
    # time a host is added or drained.
    create_table(:ember_pool) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 402) # UBID.to_base32_n("cp")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :location_id, :location, type: :uuid, null: false
      # Blanks are restored from a template, and a template is for one
      # workload, so the pool is per workload as well as per location.
      column :workload, :text, collate: '"C"', null: false
      column :target, Integer, null: false, default: 4
      column :enabled, TrueClass, null: false, default: true

      unique [:location_id, :workload], name: "ember_pool_location_workload_uidx"
    end
  end
end
