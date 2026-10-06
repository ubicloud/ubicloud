# frozen_string_literal: true

# Action types for private link services. The ids are fixed ubids whose
# base32 spells the name, as for the other action types; the Member tag gets
# PrivateLinkService:all so existing members keep access.
Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-87ff-f05aa0d85dc0', 'PrivateLinkService:view'),   -- ttzzzzzzzz021gzzz0pn0v1ew1
        ('ffffffff-ff00-835a-87c1-6a819872b4e0', 'PrivateLinkService:create'), -- ttzzzzzzzz021gz0pn0create1
        ('ffffffff-ff00-835a-87ff-f05aa07343a0', 'PrivateLinkService:edit'),   -- ttzzzzzzzz021gzzz0pn0ed1t0
        ('ffffffff-ff00-835a-87c1-6a81ae0bb4e0', 'PrivateLinkService:delete'); -- ttzzzzzzzz021gz0pn0de1ete0
    SQL

    run <<~SQL
      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff82d5028210', 'PrivateLinkService:all'); -- tazzzzzzzz021gzzzz0pn0a111
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff82d5028210', 'ffffffff-ff00-835a-87ff-f05aa0d85dc0'), -- PrivateLinkService:all -> :view
        ('ffffffff-ff00-834a-87ff-ff82d5028210', 'ffffffff-ff00-835a-87c1-6a819872b4e0'), -- PrivateLinkService:all -> :create
        ('ffffffff-ff00-834a-87ff-ff82d5028210', 'ffffffff-ff00-835a-87ff-f05aa07343a0'), -- PrivateLinkService:all -> :edit
        ('ffffffff-ff00-834a-87ff-ff82d5028210', 'ffffffff-ff00-835a-87c1-6a81ae0bb4e0'); -- PrivateLinkService:all -> :delete
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-834a-87ff-ff82d5028210'); -- Member (tazzzzzzzz021gzzzz0member0) -> PrivateLinkService:all
    SQL
  end

  down do
    run "DELETE FROM applied_action_tag WHERE tag_id = 'ffffffff-ff00-834a-87ff-ff82d5028210';"
    run "DELETE FROM applied_action_tag WHERE action_id = 'ffffffff-ff00-834a-87ff-ff82d5028210';"
    run "DELETE FROM action_type WHERE name LIKE 'PrivateLinkService:%';"
    run "DELETE FROM action_tag WHERE name = 'PrivateLinkService:all' AND project_id IS NULL;"
  end
end
