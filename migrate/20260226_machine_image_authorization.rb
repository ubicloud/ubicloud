# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-87ff-f05020d85dc0', 'MachineImage:view'),
        ('ffffffff-ff00-835a-87c1-40819872b4e0', 'MachineImage:create'),
        ('ffffffff-ff00-835a-87ff-f050207343a0', 'MachineImage:edit'),
        ('ffffffff-ff00-835a-87c1-4081ae0bb4e0', 'MachineImage:delete');
    SQL

    run <<~SQL
      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff8281028210', 'MachineImage:all');
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
