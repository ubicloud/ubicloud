# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    from(:project_invitation).exclude(inviter_id: from(:accounts).select(:id)).delete
    add_index :project_invitation, :inviter_id, name: :project_invitation_inviter_id_idx, concurrently: true
  end

  down do
    drop_index :project_invitation, :inviter_id, name: :project_invitation_inviter_id_idx, concurrently: true
  end
end
