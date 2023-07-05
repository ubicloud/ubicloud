# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :unix_user, :text, collate: '"C"', null: false
      add_column :public_key, :text, collate: '"C"', null: false
    end
  end
end
