# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:aws_location_credential) do
      column :id, :uuid, primary_key: true
      column :access_key, String, null: false, collate: '"C"'
      column :secret_key, String, null: false, collate: '"C"'
      column :region_name, String, null: false
      foreign_key :project_id, :project, type: :uuid, null: false
    end

    alter_table(:location) do
      add_foreign_key :aws_location_credential_id, :aws_location_credential, type: :uuid, null: true
      add_constraint :aws_location_credential_id_provider_check,
        {Sequel.~(aws_location_credential_id: nil) => {provider: "aws"}}
      # where aws_location_credential_id is not null, it must be unique
      add_unique_constraint :aws_location_credential_id,
        where: Sequel.~(aws_location_credential_id: nil),
        name: :aws_location_credential_id_unique
      add_unique_constraint [:name, :aws_location_credential_id],
        where: Sequel.~(aws_location_credential_id: nil),
        name: :aws_location_credential_id_name_unique
    end

    run "INSERT INTO provider (name) VALUES ('aws');"

    run <<~SQL
      INSERT INTO
        action_type (id, name)
      VALUES
        ('ffffffff-ff00-835a-87ff-f02b80d85dc0', 'AwsLocationCredential:view'),   -- ttzzzzzzzz021gzzz0aw0v1ew0
        ('ffffffff-ff00-835a-87c0-ae019872b4e0', 'AwsLocationCredential:create'), -- ttzzzzzzzz021gz0aw0create0
        ('ffffffff-ff00-835a-87ff-f02b807343a0', 'AwsLocationCredential:edit'),   -- ttzzzzzzzz021gzzz0aw0ed1t1
        ('ffffffff-ff00-835a-87c0-ae01ae0bb4e0', 'AwsLocationCredential:delete'); -- ttzzzzzzzz021gz0aw0de1ete1
    SQL

    run <<~SQL
      INSERT INTO
        action_tag (id, name)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff815c028210', 'AwsLocationCredential:all');    -- tazzzzzzzz021gzzzz0aw0a110
    SQL

    run <<~SQL
      INSERT INTO
        applied_action_tag (tag_id, action_id)
      VALUES
        ('ffffffff-ff00-834a-87ff-ff815c028210', 'ffffffff-ff00-835a-87ff-f02b80d85dc0'),
        ('ffffffff-ff00-834a-87ff-ff815c028210', 'ffffffff-ff00-835a-87c0-ae019872b4e0'),
        ('ffffffff-ff00-834a-87ff-ff815c028210', 'ffffffff-ff00-835a-87ff-f02b807343a0'),
        ('ffffffff-ff00-834a-87ff-ff815c028210', 'ffffffff-ff00-835a-87c0-ae01ae0bb4e0'),
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87ff-f02b80d85dc0'),  -- add to member
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87c0-ae019872b4e0'),  -- add to member
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87ff-f02b807343a0'),  -- add to member
        ('ffffffff-ff00-834a-87ff-ff828ea2dd80', 'ffffffff-ff00-835a-87c0-ae01ae0bb4e0');  -- add to member
    SQL
  end

  down do
    from(:location).where(provider: "aws").delete

    alter_table(:location) do
      drop_column :aws_location_credential_id
    end
    drop_table(:aws_location_credential)
    run "DELETE FROM provider WHERE name = 'aws';"

    run "DELETE FROM applied_action_tag WHERE tag_id = 'ffffffff-ff00-834a-87ff-ff815c028210';"
    run "DELETE FROM applied_action_tag WHERE action_id IN (
          'ffffffff-ff00-835a-87ff-f02b80d85dc0',
          'ffffffff-ff00-835a-87c0-ae019872b4e0',
          'ffffffff-ff00-835a-87ff-f02b807343a0',
          'ffffffff-ff00-835a-87c0-ae01ae0bb4e0'
        );"

    run "DELETE FROM action_type WHERE name LIKE 'AwsLocationCredential%';"
    run "DELETE FROM action_tag WHERE name LIKE 'AwsLocationCredential%' AND project_id IS NULL;"
  end
end
