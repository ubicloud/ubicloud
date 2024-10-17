# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :memory, :integer, null: true
      add_column :max_cpu, :integer, null: true
      add_column :max_cpu_burst, :integer, null: true
      add_column :slice_name, :text, collate: '"C"', null: true
      add_column :allowed_cpus, :text, collate: '"C"', null: true
    end

    # Update the memory amount for exisitng VMs, to match the logic from the code
    run "UPDATE vm SET memory = CASE WHEN arch = 'arm64' THEN 3.2 * cores WHEN family = 'standard-gpu' THEN 10.68 * cores ELSE 8 * cores END;"

    alter_table(:vm_host) do
      add_column :slices, :jsonb, null: true
    end
  end
end
