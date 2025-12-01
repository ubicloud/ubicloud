# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:project) do
      set_column_type :reputation, "text collate \"C\"", using: Sequel.cast(:reputation, String)
      set_column_default :reputation, "new"
      add_constraint :reputation_check, reputation: %w[new verified limited]
    end
    drop_enum :project_reputation
  end

  down do
    create_enum(:project_reputation, %w[new verified])

    from(:project).where(reputation: "limited").update(reputation: "new")

    alter_table(:project) do
      drop_constraint :reputation_check
      set_column_default :reputation, Sequel.cast("new", :project_reputation)
    end

    alter_table(:project) do
      set_column_type :reputation, :project_reputation, using: Sequel.cast(:reputation, :project_reputation)
    end
  end
end
