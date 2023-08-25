# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:sshable) do
      add_column :unix_user, :text, collate: '"C"', null: false, default: "rhizome"
    end
  end
end
