# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:address) do
      add_column :host_only, :boolean, null: false, default: false
    end
  end
end
