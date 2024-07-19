# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:project_reputation, %w[new verified])

    alter_table(:project) do
      add_column :reputation, :project_reputation, default: "new", null: false
    end

    run "UPDATE project SET reputation = 'verified' WHERE id IN (SELECT project_id FROM invoice WHERE (content->'cost')::float > 5)"
  end
end
