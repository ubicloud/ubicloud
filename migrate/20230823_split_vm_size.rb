# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm) do
      add_column :family, String, collate: '"C"'
      add_column :cores, Integer
    end

    run "UPDATE vm SET family = split_part(size, '-', 1), cores = (split_part(size, '-', 2)::integer) / 2"

    alter_table(:vm) do
      drop_column :size
      set_column_not_null :family
      set_column_not_null :cores
    end
  end

  down do
    alter_table(:vm) do
      add_column :size, String, collate: '"C"'
    end

    run "UPDATE vm SET size = family || '-' || (2 * cores)::text"

    alter_table(:vm) do
      drop_column :family
      drop_column :cores
      set_column_not_null :size
    end
  end
end
