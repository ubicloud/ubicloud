# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:action_type) do
      uuid :id, primary_key: true
      String :name, unique: true, null: false
    end
    # Action Type UUID primary keys created via:
    # UBID.generate_vanity_action_type(action).to_uuid
    # This shows the generated UBIDs, but those are removed before inserting.
    from(:action_type).import([:id, :name],
      [["ffffffff-ff00-835a-8001-6c01ae0bb4e0", "Project:delete", "ttzzzzzzzz021g00pr0de1ete0"],
        ["ffffffff-ff00-835a-8000-005b007343a0", "Project:edit", "ttzzzzzzzz021g0000pr0ed1t0"],
        ["ffffffff-ff00-835a-8000-005b00d85dc0", "Project:view", "ttzzzzzzzz021g0000pr0v1ew1"],
        ["ffffffff-ff00-835a-8000-005b00de5d80", "Project:user", "ttzzzzzzzz021g0000pr0vser0"],
        ["ffffffff-ff00-835a-802d-802c21086b00", "Project:billing", "ttzzzzzzzz021g0pr0b1111ng1"],
        ["ffffffff-ff00-835a-8001-6c0201d476b0", "Project:github", "ttzzzzzzzz021g00pr0g1thvb0"],
        ["ffffffff-ff00-835a-802d-80676b969500", "Project:subjtag", "ttzzzzzzzz021g0pr0svbjtag0"],
        ["ffffffff-ff00-835a-8001-6c014cd69500", "Project:acttag", "ttzzzzzzzz021g00pr0acttag1"],
        ["ffffffff-ff00-835a-8001-6c000b969500", "Project:objtag", "ttzzzzzzzz021g00pr00bjtag1"],
        ["ffffffff-ff00-835a-8001-6c014c63b390", "Project:access", "ttzzzzzzzz021g00pr0access1"],
        ["ffffffff-ff00-835a-8000-0b601a04dd50", "Project:token", "ttzzzzzzzz021g000pr0t0ken0"],
        ["ffffffff-ff00-835a-8001-ba019872b4e0", "Vm:create", "ttzzzzzzzz021g00vm0create0"],
        ["ffffffff-ff00-835a-8001-ba01ae0bb4e0", "Vm:delete", "ttzzzzzzzz021g00vm0de1ete1"],
        ["ffffffff-ff00-835a-8000-006e80d85dc0", "Vm:view", "ttzzzzzzzz021g0000vm0v1ew0"],
        ["ffffffff-ff00-835a-8001-6c819872b4e0", "PrivateSubnet:create", "ttzzzzzzzz021g00ps0create0"],
        ["ffffffff-ff00-835a-8001-6c81ae0bb4e0", "PrivateSubnet:delete", "ttzzzzzzzz021g00ps0de1ete1"],
        ["ffffffff-ff00-835a-8000-005b207343a0", "PrivateSubnet:edit", "ttzzzzzzzz021g0000ps0ed1t1"],
        ["ffffffff-ff00-835a-8000-005b20d85dc0", "PrivateSubnet:view", "ttzzzzzzzz021g0000ps0v1ew0"],
        ["ffffffff-ff00-835a-802d-903015ab99a0", "PrivateSubnet:connect", "ttzzzzzzzz021g0ps0c0nnect1"],
        ["ffffffff-ff00-835a-802d-903439602b50", "PrivateSubnet:disconnect", "ttzzzzzzzz021g0ps0d1sc0nn0"],
        ["ffffffff-ff00-835a-8000-fe019872b4e0", "Firewall:create", "ttzzzzzzzz021g00fw0create1"],
        ["ffffffff-ff00-835a-8000-fe01ae0bb4e0", "Firewall:delete", "ttzzzzzzzz021g00fw0de1ete0"],
        ["ffffffff-ff00-835a-8000-003f807343a0", "Firewall:edit", "ttzzzzzzzz021g0000fw0ed1t0"],
        ["ffffffff-ff00-835a-8000-003f80d85dc0", "Firewall:view", "ttzzzzzzzz021g0000fw0v1ew1"],
        ["ffffffff-ff00-835a-8000-15819872b4e0", "LoadBalancer:create", "ttzzzzzzzz021g001b0create0"],
        ["ffffffff-ff00-835a-8000-1581ae0bb4e0", "LoadBalancer:delete", "ttzzzzzzzz021g001b0de1ete1"],
        ["ffffffff-ff00-835a-8000-0005607343a0", "LoadBalancer:edit", "ttzzzzzzzz021g00001b0ed1t1"],
        ["ffffffff-ff00-835a-8000-000560d85dc0", "LoadBalancer:view", "ttzzzzzzzz021g00001b0v1ew0"],
        ["ffffffff-ff00-835a-8001-68019872b4e0", "Postgres:create", "ttzzzzzzzz021g00pg0create0"],
        ["ffffffff-ff00-835a-8001-6801ae0bb4e0", "Postgres:delete", "ttzzzzzzzz021g00pg0de1ete1"],
        ["ffffffff-ff00-835a-8000-005a007343a0", "Postgres:edit", "ttzzzzzzzz021g0000pg0ed1t1"],
        ["ffffffff-ff00-835a-8000-005a00d85dc0", "Postgres:view", "ttzzzzzzzz021g0000pg0v1ew0"],
        ["ffffffff-ff00-835a-8000-0059e07343a0", "Postgres:Firewall:edit", "ttzzzzzzzz021g0000pf0ed1t0"],
        ["ffffffff-ff00-835a-8000-0059e0d85dc0", "Postgres:Firewall:view", "ttzzzzzzzz021g0000pf0v1ew1"],
        ["ffffffff-ff00-835a-8000-00033a029ad0", "SubjectTag:add", "ttzzzzzzzz021g00000st0add1"],
        ["ffffffff-ff00-835a-8001-9d030ea036e0", "SubjectTag:remove", "ttzzzzzzzz021g00st0rem0ve1"],
        ["ffffffff-ff00-835a-8000-00015a029ad0", "ActionTag:add", "ttzzzzzzzz021g00000at0add0"],
        ["ffffffff-ff00-835a-8000-ad030ea036e0", "ActionTag:remove", "ttzzzzzzzz021g00at0rem0ve0"],
        ["ffffffff-ff00-835a-8002-10841a029ad0", "ObjectTag:add", "ttzzzzzzzz021g011110t0add0"],
        ["ffffffff-ff00-835a-8002-0d030ea036e0", "ObjectTag:remove", "ttzzzzzzzz021g010t0rem0ve1"]].each(&:pop))

    %w[subject action object].each do |tag_type|
      create_table(:"#{tag_type}_tag") do
        uuid :id, primary_key: true
        foreign_key :project_id, :project, type: :uuid, null: (tag_type == "action")
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

    # Action Tag UUID primary keys created via:
    # UBID.generate_vanity_action_tag(name).to_uuid
    # This shows the generated UBIDs, but those are removed before inserting.
    # These non-project specific action tags will be managed by Ubicloud developers.
    action_tags =
      [["ffffffff-ff00-834a-8000-0002d8028210", "Project:all", "tazzzzzzzz021g00000pr0a110"],
        ["ffffffff-ff00-834a-8000-000374028210", "Vm:all", "tazzzzzzzz021g00000vm0a111"],
        ["ffffffff-ff00-834a-8000-0002d9028210", "PrivateSubnet:all", "tazzzzzzzz021g00000ps0a111"],
        ["ffffffff-ff00-834a-8000-0001fc028210", "Firewall:all", "tazzzzzzzz021g00000fw0a110"],
        ["ffffffff-ff00-834a-8000-00002b028210", "LoadBalancer:all", "tazzzzzzzz021g000001b0a111"],
        ["ffffffff-ff00-834a-8000-0002d0028210", "Postgres:all", "tazzzzzzzz021g00000pg0a111"],
        ["ffffffff-ff00-834a-8000-00028ea2dd80", "Member", "tazzzzzzzz021g00000member0"]].each(&:pop)

    from(:action_tag).import([:id, :name], action_tags)

    member_id = action_tags.pop.first
    # *:all action tags have all related actions in them
    action_tags.each do |id, name|
      name = name.delete_suffix(":all")
      from(:applied_action_tag).insert([:tag_id, :action_id],
        from(:action_type)
          .where(Sequel.like(:name, "#{name}:%"))
          .select(id, :id))
    end
    # Member action tag has Project:{view,github} actions
    from(:applied_action_tag).insert([:tag_id, :action_id],
      from(:action_type)
        .where(name: %w[Project:view Project:github])
        .select(Sequel.cast(member_id, :uuid), :id)
        .union(
          # and non-Project :all tags
          from(:action_tag)
            .where(project_id: nil)
            .where(Sequel.like(:name, "%:all"))
            .exclude(name: "Project:all")
            .select(member_id, :id)
        ))

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
