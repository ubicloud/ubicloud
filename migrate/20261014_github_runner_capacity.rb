# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:github_runner_capacity) do
      column :name, :text, primary_key: true, collate: '"C"'
      Integer :total_cores, null: false, default: 0
      Integer :total_hugepages_1g, null: false, default: 0
      Integer :used_cores, null: false, default: 0
      Integer :used_hugepages_1g, null: false, default: 0
      Integer :used_vcpus, null: false, default: 0
      Integer :used_runners, null: false, default: 0
      column :reconciled_at, :timestamptz
    end
    run "ALTER TABLE github_runner_capacity SET (fillfactor = 20)"
    from(:github_runner_capacity).import([:name], [["arm64-standard"], ["aws"], ["x64-premium"], ["x64-standard"]])

    alter_table(:github_runner) do
      add_column :capacity_pool, :text, collate: '"C"'
    end
  end

  down do
    alter_table(:github_runner) do
      drop_column :capacity_pool
    end
    drop_table(:github_runner_capacity)
  end
end
