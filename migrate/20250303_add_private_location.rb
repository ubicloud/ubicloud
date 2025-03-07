# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:location_credential) do
      column :access_key, String, null: false, collate: '"C"'
      column :secret_key, String, null: false, collate: '"C"'
      foreign_key :id, :location, type: :uuid, null: false, primary_key: true
    end

    alter_table(:location) do
      add_foreign_key :project_id, :project, type: :uuid, null: true
      add_index [:project_id, :display_name], name: :location_project_id_display_name_uidx, unique: true # rubocop:disable Sequel/ConcurrentIndex
      add_index [:project_id, :ui_name], name: :location_project_id_ui_name_uidx, unique: true # rubocop:disable Sequel/ConcurrentIndex
    end

    run "INSERT INTO provider (name) VALUES ('aws');"

    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-87ff-f00400d85dc0', 'Location:view'),   -- ttzzzzzzzz021gzzz0100v1ew0
        ('ffffffff-ff00-835a-87c0-10019872b4e0', 'Location:create'), -- ttzzzzzzzz021gz0100create0
        ('ffffffff-ff00-835a-87ff-f004007343a0', 'Location:edit'),   -- ttzzzzzzzz021gzzz0100ed1t1
        ('ffffffff-ff00-835a-87c0-1001ae0bb4e0', 'Location:delete'); -- ttzzzzzzzz021gz0100de1ete1
    SQL

    run <<~SQL
      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff8020028210', 'Location:all');    -- tazzzzzzzz021gzzzz0100a110
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff8020028210', 'ffffffff-ff00-835a-87ff-f00400d85dc0'),
        ('ffffffff-ff00-834a-87ff-ff8020028210', 'ffffffff-ff00-835a-87c0-10019872b4e0'),
        ('ffffffff-ff00-834a-87ff-ff8020028210', 'ffffffff-ff00-835a-87ff-f004007343a0'),
        ('ffffffff-ff00-834a-87ff-ff8020028210', 'ffffffff-ff00-835a-87c0-1001ae0bb4e0'),
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87ff-f00400d85dc0'),  -- add to member
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87c0-10019872b4e0'),  -- add to member
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87ff-f004007343a0'),  -- add to member
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87c0-1001ae0bb4e0');  -- add to member
    SQL
  end

  down do
    from(:location).where(provider: "aws").delete

    alter_table(:location) do
      drop_column :project_id
    end
    drop_table(:location_credential)
    run "DELETE FROM provider WHERE name = 'aws';"

    run "DELETE FROM applied_action_tag WHERE tag_id = 'ffffffff-ff00-834a-87ff-ff815c028210';"
    run "DELETE FROM applied_action_tag WHERE action_id IN (
          'ffffffff-ff00-835a-87ff-f00400d85dc0',
          'ffffffff-ff00-835a-87c0-10019872b4e0',
          'ffffffff-ff00-835a-87ff-f004007343a0',
          'ffffffff-ff00-835a-87c0-1001ae0bb4e0'
        );"

    run "DELETE FROM action_type WHERE name LIKE 'Location%';"
    run "DELETE FROM action_tag WHERE name LIKE 'Location%' AND project_id IS NULL;"
  end
end
