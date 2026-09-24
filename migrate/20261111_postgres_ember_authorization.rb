# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-0000-0031c0d85dc0', 'PostgresEmber:view'),   -- ttzzzzzzzz02100000ce0v1ew0
        ('ffffffff-ff00-835a-0000-06399872b4e0', 'PostgresEmber:create'), -- ttzzzzzzzz0210000cecreate0
        ('ffffffff-ff00-835a-0000-0031c07343a0', 'PostgresEmber:edit'),   -- ttzzzzzzzz02100000ce0ed1t1
        ('ffffffff-ff00-835a-0000-0639ae0bb4e0', 'PostgresEmber:delete'); -- ttzzzzzzzz0210000cede1ete1
    SQL

    run <<~SQL
      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-0000-0031c0028210', 'PostgresEmber:all'); -- tazzzzzzzz02100000ce00a111
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-0000-0031c0028210', 'ffffffff-ff00-835a-0000-0031c0d85dc0'), -- PostgresEmber:all -> :view
        ('ffffffff-ff00-834a-0000-0031c0028210', 'ffffffff-ff00-835a-0000-06399872b4e0'), -- PostgresEmber:all -> :create
        ('ffffffff-ff00-834a-0000-0031c0028210', 'ffffffff-ff00-835a-0000-0031c07343a0'), -- PostgresEmber:all -> :edit
        ('ffffffff-ff00-834a-0000-0031c0028210', 'ffffffff-ff00-835a-0000-0639ae0bb4e0'); -- PostgresEmber:all -> :delete
    SQL

    # An ember is a member-level resource, like a VM or a machine image.
    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-834a-0000-0031c0028210'); -- Member -> PostgresEmber:all
    SQL
  end

  down do
    run "DELETE FROM applied_action_tag WHERE tag_id = 'ffffffff-ff00-834a-0000-0031c0028210';"
    run "DELETE FROM applied_action_tag WHERE action_id = 'ffffffff-ff00-834a-0000-0031c0028210';"
    run "DELETE FROM action_type WHERE name LIKE 'PostgresEmber:%';"
    run "DELETE FROM action_tag WHERE name LIKE 'PostgresEmber:%' AND project_id IS NULL;"
  end
end
