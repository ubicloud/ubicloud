# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table :strand do
      add_column :try, Integer, default: 0, null: false
    end
  end
end
