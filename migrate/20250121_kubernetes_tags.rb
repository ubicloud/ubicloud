# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-87ff-f04d80d85dc0', 'KubernetesCluster:view'),   -- ttzzzzzzzz021gzzz0kc0v1ew0
        ('ffffffff-ff00-835a-87c1-36019872b4e0', 'KubernetesCluster:create'), -- ttzzzzzzzz021gz0kc0create0
        ('ffffffff-ff00-835a-87ff-f04d807343a0', 'KubernetesCluster:edit'),   -- ttzzzzzzzz021gzzz0kc0ed1t1
        ('ffffffff-ff00-835a-87c1-3601ae0bb4e0', 'KubernetesCluster:delete'); -- ttzzzzzzzz021gz0kc0de1ete1
    SQL

    run <<~SQL
      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff826c028210', 'KubernetesCluster:all');    -- tazzzzzzzz021gzzzz0kc0a110
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff826c028210', 'ffffffff-ff00-835a-87ff-f04d80d85dc0'),
        ('ffffffff-ff00-834a-87ff-ff826c028210', 'ffffffff-ff00-835a-87c1-36019872b4e0'),
        ('ffffffff-ff00-834a-87ff-ff826c028210', 'ffffffff-ff00-835a-87ff-f04d807343a0'),
        ('ffffffff-ff00-834a-87ff-ff826c028210', 'ffffffff-ff00-835a-87c1-3601ae0bb4e0');
    SQL
  end

  down do
    run "DELETE FROM applied_action_tag WHERE tag_id = 'ffffffff-ff00-834a-87ff-ff826c028210';"
    run "DELETE FROM action_type WHERE name LIKE 'KubernetesCluster%';"
    run "DELETE FROM action_tag WHERE name LIKE 'KubernetesCluster%' AND project_id IS NULL;"
  end
end
