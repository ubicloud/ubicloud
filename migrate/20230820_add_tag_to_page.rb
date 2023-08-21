# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:page) do
      add_column :tag, :text, collate: '"C"'
      add_unique_constraint :tag
    end

    run "UPDATE page SET tag = id"

    alter_table(:page) do
      set_column_not_null :tag
    end
  end

  down do
    alter_table(:page) do
      drop_column :tag
    end
  end
end
