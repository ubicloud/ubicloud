# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-87ff-f05020d85dc0', 'MachineImage:view'),   -- ttzzzzzzzz021gzzz0m10v1ew0
        ('ffffffff-ff00-835a-87c1-40819872b4e0', 'MachineImage:create'), -- ttzzzzzzzz021gz0m10create0
        ('ffffffff-ff00-835a-87ff-f050207343a0', 'MachineImage:edit'),   -- ttzzzzzzzz021gzzz0m10ed1t1
        ('ffffffff-ff00-835a-87c1-4081ae0bb4e0', 'MachineImage:delete'); -- ttzzzzzzzz021gz0m10de1ete1
    SQL

    run <<~SQL
      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff8281028210', 'MachineImage:all'); -- tazzzzzzzz021gzzzz0m10a110
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff8281028210', 'ffffffff-ff00-835a-87ff-f05020d85dc0'),
        ('ffffffff-ff00-834a-87ff-ff8281028210', 'ffffffff-ff00-835a-87c1-40819872b4e0'),
        ('ffffffff-ff00-834a-87ff-ff8281028210', 'ffffffff-ff00-835a-87ff-f050207343a0'),
        ('ffffffff-ff00-834a-87ff-ff8281028210', 'ffffffff-ff00-835a-87c1-4081ae0bb4e0');
    SQL

    # Add MachineImage:all to the Member action tag
    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-834a-87ff-ff8281028210');
    SQL
  end

  down do
    run "DELETE FROM applied_action_tag WHERE tag_id = 'ffffffff-ff00-834a-87ff-ff8281028210';"
    run "DELETE FROM applied_action_tag WHERE action_id = 'ffffffff-ff00-834a-87ff-ff8281028210';"
    run "DELETE FROM action_type WHERE name LIKE 'MachineImage%';"
    run "DELETE FROM action_tag WHERE name LIKE 'MachineImage%' AND project_id IS NULL;"
  end
end
