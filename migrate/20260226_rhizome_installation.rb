# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:rhizome_installation) do
      foreign_key :id, :sshable, type: :uuid, primary_key: true, on_delete: :cascade
      column :folder, String, collate: '"C"', null: false
      column :commit, String, collate: '"C"', null: false
      column :digest, String, collate: '"C"', null: false
      column :installed_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
