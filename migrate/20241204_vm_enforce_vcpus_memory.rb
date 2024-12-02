# frozen_string_literal: true

Sequel.migration do
  up do
    # Update the memory & vcpus for exisitng VMs, to match the logic from the
    # code. Then enforce the NOT NULL constraint on the columns.
    run <<-SQL
    UPDATE vm
    SET
      vcpus = CASE
        WHEN arch = 'arm64' THEN cores
        ELSE 2 * cores
      END,
      memory_gib = CASE
        WHEN arch = 'arm64' THEN 3.2 * cores
        WHEN family = 'standard-gpu' THEN 10.68 * cores
        ELSE 8 * cores
      END
    WHERE vcpus IS NULL OR memory_gib IS NULL;
    SQL

    run <<-SQL
    ALTER TABLE vm
      ALTER COLUMN vcpus SET NOT NULL,
      ALTER COLUMN memory_gib SET NOT NULL;
    SQL
  end

  down do
    run <<-SQL
    ALTER TABLE vm
      ALTER COLUMN vcpus DROP NOT NULL,
      ALTER COLUMN memory_gib DROP NOT NULL;
    SQL
  end
end
