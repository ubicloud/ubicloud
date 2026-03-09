# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-802d-202b6d0e8200', 'Project:auditlog'); -- ttzzzzzzzz021g0pj0avd1t100
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff82d2028210', 'ffffffff-ff00-835a-802d-202b6d0e8200'); -- add to Project:all
    SQL
  end

  down do
    run "DELETE FROM applied_action_tag WHERE action_id = 'ffffffff-ff00-835a-802d-202b6d0e8200';"
    run "DELETE FROM action_type WHERE id = 'ffffffff-ff00-835a-802d-202b6d0e8200';"
  end
end
