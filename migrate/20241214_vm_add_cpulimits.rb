# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :cpu_percent_limit, :integer, null: true
      add_column :cpu_burst_percent_limit, :integer, null: true
    end

    # Update the memory amount for exisitng VMs, to match the logic from the code
    run "UPDATE vm SET memory_gib = CASE WHEN arch = 'arm64' THEN 3.2 * cores WHEN family = 'standard-gpu' THEN 10.68 * cores ELSE 8 * cores END;"
  end
end
