# frozen_string_literal: true

Sequel.migration do
  up do
    # Update the new columns for storing total and used memory
    # with values from the old ones.
    run <<-SQL
    UPDATE vm_host_slice
    SET
      total_memory_gib = total_memory_1g,
      used_memory_gib = used_memory_1g
    WHERE total_memory_gib IS NULL OR used_memory_gib IS NULL;
    SQL

    run <<-SQL
    ALTER TABLE vm_host_slice
      ALTER COLUMN total_memory_gib SET NOT NULL,
      ALTER COLUMN used_memory_gib SET NOT NULL,
      ALTER COLUMN total_memory_1g DROP NOT NULL,
      ALTER COLUMN used_memory_1g DROP NOT NULL;
    SQL

    run <<-SQL
    ALTER TABLE vm_host_slice
      DROP CONSTRAINT memory_allocation_limit,
      ADD CONSTRAINT memory_allocation_limit CHECK (used_memory_gib <= total_memory_gib);
    SQL

    run <<-SQL
    ALTER TABLE vm_host_slice
      DROP CONSTRAINT used_memory_not_negative,
      ADD CONSTRAINT used_memory_not_negative CHECK (used_memory_gib >= 0);
    SQL
  end

  down do
    run <<-SQL
    ALTER TABLE vm_host_slice
      ALTER COLUMN total_memory_1g SET NOT NULL,
      ALTER COLUMN used_memory_1g SET NOT NULL,
      ALTER COLUMN total_memory_gib DROP NOT NULL,
      ALTER COLUMN used_memory_gib DROP NOT NULL;
    SQL

    run <<-SQL
    ALTER TABLE vm_host_slice
      DROP CONSTRAINT used_memory_not_negative,
      ADD CONSTRAINT used_memory_not_negative CHECK (used_memory_1g >= 0);
    SQL

    run <<-SQL
    ALTER TABLE vm_host_slice
      DROP CONSTRAINT memory_allocation_limit,
      ADD CONSTRAINT memory_allocation_limit CHECK (used_memory_1g <= total_memory_1g);
    SQL
  end
end
