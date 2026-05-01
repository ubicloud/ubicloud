# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:page_root_resource) do
      foreign_key :page_id, :page, type: :uuid, on_delete: :cascade
      uuid :root_resource_id # currently either VmHost, GithubInstallation, or PostgresResource id
      boolean :duplicate, null: false
      Time :at, null: false, default: Sequel::CURRENT_TIMESTAMP
      primary_key [:root_resource_id, :page_id]
      index :page_id
    end
  end
end
