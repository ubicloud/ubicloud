# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:access_policy) do
      add_column :managed, :boolean, null: false, default: false
    end

    alter_table(:project_invitation) do
      add_column :policy, :text, collate: '"C"'
    end
  end
end
