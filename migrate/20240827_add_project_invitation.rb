# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:project_invitation) do
      column :project_id, :uuid, null: false
      column :email, :text, collate: '"C"', null: false
      column :inviter_id, :uuid, null: false
      column :expires_at, :timestamp, null: false
      primary_key [:project_id, :email]
    end
  end
end
