# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:action_type) do
      uuid :id, primary_key: true
      String :name, unique: true, null: false
    end
    # Action Type UUID primary keys created via:
    # UBID.from_parts(i, UBID::TYPE_ACTION_TYPE, 0, i).to_uuid
    from(:action_type).import([:id, :name],
      [["00000000-0001-835a-8000-000000000001", "Project:delete"],          # 1
        ["00000000-0002-835a-8000-000000000002", "Project:edit"],
        ["00000000-0003-835a-8000-000000000003", "Project:view"],
        ["00000000-0004-835a-8000-000000000004", "Project:user"],
        ["00000000-0005-835a-8000-000000000005", "Project:billing"],
        ["00000000-0006-835a-8000-000000000006", "Project:github"],
        ["00000000-0007-835a-8000-000000000007", "Vm:create"],
        ["00000000-0008-835a-8000-000000000008", "Vm:delete"],
        ["00000000-0009-835a-8000-000000000009", "Vm:view"],
        ["00000000-000a-835a-8000-00000000000a", "PrivateSubnet:create"],
        ["00000000-000b-835a-8000-00000000000b", "PrivateSubnet:delete"],
        ["00000000-000c-835a-8000-00000000000c", "PrivateSubnet:edit"],
        ["00000000-000d-835a-8000-00000000000d", "PrivateSubnet:view"],
        ["00000000-000e-835a-8000-00000000000e", "PrivateSubnet:connect"],
        ["00000000-000f-835a-8000-00000000000f", "PrivateSubnet:disconnect"],
        ["00000000-0010-835a-8000-000000000010", "Firewall:create"],
        ["00000000-0011-835a-8000-000000000011", "Firewall:delete"],
        ["00000000-0012-835a-8000-000000000012", "Firewall:edit"],
        ["00000000-0013-835a-8000-000000000013", "Firewall:view"],
        ["00000000-0014-835a-8000-000000000014", "LoadBalancer:create"],
        ["00000000-0015-835a-8000-000000000015", "LoadBalancer:delete"],
        ["00000000-0016-835a-8000-000000000016", "LoadBalancer:edit"],
        ["00000000-0017-835a-8000-000000000017", "LoadBalancer:view"],
        ["00000000-0018-835a-8000-000000000018", "Postgres:create"],
        ["00000000-0019-835a-8000-000000000019", "Postgres:delete"],
        ["00000000-001a-835a-8000-00000000001a", "Postgres:edit"],
        ["00000000-001b-835a-8000-00000000001b", "Postgres:view"],
        ["00000000-001c-835a-8000-00000000001c", "Postgres:Firewall:edit"],
        ["00000000-001d-835a-8000-00000000001d", "Postgres:Firewall:view"]]) # 29

    %w[subject action object].each do |tag_type|
      create_table(:"#{tag_type}_tag") do
        uuid :id, primary_key: true
        foreign_key :project_id, :project, type: :uuid, null: false
        String :name, null: false

        index [:project_id, :name], unique: true
      end

      create_table(:"applied_#{tag_type}_tag") do
        foreign_key :tag_id, :"#{tag_type}_tag", type: :uuid
        tag_column = :"#{tag_type}_id"
        uuid tag_column

        primary_key [:tag_id, tag_column]
        index [tag_column, :tag_id]
        constraint :no_self_tag, Sequel.~(tag_id: tag_column)
      end
    end

    create_table(:access_control_entry) do
      uuid :id, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      uuid :subject_id, null: false
      uuid :action_id, null: true
      uuid :object_id, null: true

      index [:project_id, :subject_id, :action_id, :object_id]
    end
  end

  down do
    drop_table :access_control_entry
    %w[subject action object].each do |tag_type|
      drop_table(:"applied_#{tag_type}_tag", :"#{tag_type}_tag")
    end
    drop_table :action_type
  end
end
