# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:page) do
      add_column :resource_id, :uuid
    end
  end
end
