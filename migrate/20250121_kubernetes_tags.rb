# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-87ff-f04d80d85dc0', 'KubernetesCluster:view'),
        ('ffffffff-ff00-835a-87c1-36019872b4e0', 'KubernetesCluster:create'),
        ('ffffffff-ff00-835a-87ff-f04d807343a0', 'KubernetesCluster:edit'),
        ('ffffffff-ff00-835a-87c1-3601ae0bb4e0', 'KubernetesCluster:delete');

      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff826c028210', 'KubernetesCluster:all');

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
    run <<~SQL
      DELETE FROM applied_action_tag WHERE tag_id = 'ffffffff-ff00-834a-87ff-ff826c028210';
      DELETE FROM action_type WHERE name LIKE 'KubernetesCluster%';
      DELETE FROM action_tag WHERE name LIKE 'KubernetesCluster%';
    SQL
  end
end
