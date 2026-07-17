# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-802d-00341ca840a0', 'Postgres:download_credentials'); -- ttzzzzzzzz021g0pg0d0wn10a1
    SQL

    # Add Postgres:download_credentials to the Postgres:all tag. Deliberately not
    # added to the Member tag: this action can mint credentials that read a resource's
    # entire backup/WAL history, so it should require an explicit grant, same posture
    # as Postgres:delete.
    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff82d0028210', 'ffffffff-ff00-835a-802d-00341ca840a0'); -- Postgres:all -> :download_credentials
    SQL
  end

  down do
    run "DELETE FROM applied_action_tag WHERE action_id = 'ffffffff-ff00-835a-802d-00341ca840a0';"
    run "DELETE FROM action_type WHERE id = 'ffffffff-ff00-835a-802d-00341ca840a0';"
  end
end
