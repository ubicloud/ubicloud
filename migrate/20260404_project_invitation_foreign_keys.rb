# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project_invitation) do
      add_foreign_key [:project_id], :project, name: :project_invitation_project_id_fkey
      add_foreign_key [:inviter_id], :accounts, name: :project_invitation_inviter_id_fkey
    end
  end
end
