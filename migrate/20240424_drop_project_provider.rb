# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      drop_column :provider
    end
  end
end
