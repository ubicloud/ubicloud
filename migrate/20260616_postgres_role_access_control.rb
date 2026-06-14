# frozen_string_literal: true

Sequel.migration do
  up do
    # Denormalize the project onto the role so it can be a project-scoped access
    # control object (authorization checks SELECT project_id from the object's
    # own table).
    alter_table(:postgres_managed_role) do
      add_foreign_key :project_id, :project, type: :uuid
    end

    from(:postgres_managed_role).update(
      project_id: from(:postgres_resource)
        .where(id: Sequel[:postgres_managed_role][:postgres_resource_id])
        .select(:project_id),
    )

    alter_table(:postgres_managed_role) do
      set_column_not_null :project_id
      add_index :project_id # rubocop:disable Sequel/ConcurrentIndex
    end

    # UBID.generate_vanity_action_type("PostgresRole:assume") => ttzzzzzzzz021gz0mr0assvme1
    from(:action_type).insert(id: "ffffffff-ff00-835a-87c1-4c0159cee8e0", name: "PostgresRole:assume")
  end

  down do
    from(:action_type).where(name: "PostgresRole:assume").delete
    alter_table(:postgres_managed_role) do
      drop_index :project_id # rubocop:disable Sequel/ConcurrentIndex
      drop_column :project_id
    end
  end
end
