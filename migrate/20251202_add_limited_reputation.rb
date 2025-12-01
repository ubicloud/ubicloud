# frozen_string_literal: true

Sequel.migration do
  up do
    # Add temporary VARCHAR column
    alter_table(:project) do
      add_column :reputation_new, String, collate: '"C"', default: "new"
    end

    # Copy data from enum columns to new column
    run "UPDATE project SET reputation_new = reputation::text"

    # Drop old enum column
    alter_table(:project) do
      drop_column :reputation
    end

    # Rename new column
    alter_table(:project) do
      rename_column :reputation_new, :reputation
    end

    # Add CHECK constraints
    alter_table(:project) do
      add_constraint(:reputation_check, Sequel.lit("reputation IN ('new', 'verified', 'limited')"))
      set_column_not_null :reputation
    end

    # Drop the enum type
    drop_enum(:project_reputation)
  end

  down do
    # Recreate enum type
    create_enum(:project_reputation, %w[new verified])

    # Add temporary enum columns
    alter_table(:project) do
      add_column :reputation_enum, :project_reputation, default: "new"
    end

    # Copy data back
    run "UPDATE project SET reputation = 'new' WHERE reputation = 'limited'"
    run "UPDATE project SET reputation_enum = reputation::project_reputation"

    # Drop CHECK constrained columns
    alter_table(:project) do
      drop_constraint(:reputation_check)
      set_column_not_null :reputation_enum
      drop_column :reputation
    end

    # Rename enum columns back
    alter_table(:project) do
      rename_column :reputation_enum, :reputation
    end
  end
end
