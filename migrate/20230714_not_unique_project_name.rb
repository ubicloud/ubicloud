# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:project) do
      drop_constraint :project_name_key, type: :unique
    end
  end

  down do
    alter_table(:project) do
      add_unique_constraint :name
    end
  end
end
