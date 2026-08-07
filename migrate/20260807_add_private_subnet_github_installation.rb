# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:private_subnet) do
      add_foreign_key :github_installation_id, :github_installation, type: :uuid
      add_unique_constraint :github_installation_id, name: :private_subnet_github_installation_id_uidx
    end
  end

  down do
    alter_table(:private_subnet) do
      drop_column :github_installation_id
    end
  end
end
