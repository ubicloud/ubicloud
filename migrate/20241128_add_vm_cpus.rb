# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :cpus, :integer
    end

    # Update the cpus amount for exisitng VMs, to match the logic from the code
    run "UPDATE vm SET cpus = CASE WHEN arch = 'arm64' THEN cores ELSE 2 * cores END;"
  end
end
