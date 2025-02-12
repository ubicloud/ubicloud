# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:provider) do
      column :display_name, String, null: false
      column :internal_name, String, null: false
      column :id, :uuid, primary_key: true
    end

    create_table(:provider_location) do
      column :display_name, String, null: false
      column :internal_name, String, null: false
      column :ui_name, String, null: false
      column :visible, :boolean, null: false
      column :id, :uuid, primary_key: true
      foreign_key :provider_id, :provider, type: :uuid, null: false
    end
  end
end
