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
      [["ffffffff-ff00-835a-87c1-6901ae0bb4e0", "Project:delete", "ttzzzzzzzz021gz0pj0de1ete1"],
        ["ffffffff-ff00-835a-87ff-f05a407343a0", "Project:edit", "ttzzzzzzzz021gzzz0pj0ed1t1"],
        ["ffffffff-ff00-835a-87ff-f05a40d85dc0", "Project:view", "ttzzzzzzzz021gzzz0pj0v1ew0"],
        ["ffffffff-ff00-835a-87ff-f05a40de5d80", "Project:user", "ttzzzzzzzz021gzzz0pj0vser1"],
        ["ffffffff-ff00-835a-802d-202c21086b00", "Project:billing", "ttzzzzzzzz021g0pj0b1111ng1"],
        ["ffffffff-ff00-835a-87c1-690201d476b0", "Project:github", "ttzzzzzzzz021gz0pj0g1thvb1"],
        ["ffffffff-ff00-835a-802d-20676b969500", "Project:subjtag", "ttzzzzzzzz021g0pj0svbjtag0"],
        ["ffffffff-ff00-835a-87c1-69014cd69500", "Project:acttag", "ttzzzzzzzz021gz0pj0acttag0"],
        ["ffffffff-ff00-835a-87c1-69000b969500", "Project:objtag", "ttzzzzzzzz021gz0pj00bjtag0"],
        ["ffffffff-ff00-835a-802d-206c2ee298c0", "Project:viewaccess", "ttzzzzzzzz021g0pj0v1ewacc1"],
        ["ffffffff-ff00-835a-802d-2039a1d298c0", "Project:editaccess", "ttzzzzzzzz021g0pj0ed1tacc0"],
        ["ffffffff-ff00-835a-87fe-0b481a04dd50", "Project:token", "ttzzzzzzzz021gzz0pj0t0ken0"],
        ["ffffffff-ff00-835a-87c1-ba019872b4e0", "Vm:create", "ttzzzzzzzz021gz0vm0create1"],
        ["ffffffff-ff00-835a-87c1-ba01ae0bb4e0", "Vm:delete", "ttzzzzzzzz021gz0vm0de1ete0"],
        ["ffffffff-ff00-835a-87ff-f06e807343a0", "Vm:edit", "ttzzzzzzzz021gzzz0vm0ed1t0"],
        ["ffffffff-ff00-835a-87ff-f06e80d85dc0", "Vm:view", "ttzzzzzzzz021gzzz0vm0v1ew1"],
        ["ffffffff-ff00-835a-87c1-6c819872b4e0", "PrivateSubnet:create", "ttzzzzzzzz021gz0ps0create1"],
        ["ffffffff-ff00-835a-87c1-6c81ae0bb4e0", "PrivateSubnet:delete", "ttzzzzzzzz021gz0ps0de1ete0"],
        ["ffffffff-ff00-835a-87ff-f05b207343a0", "PrivateSubnet:edit", "ttzzzzzzzz021gzzz0ps0ed1t0"],
        ["ffffffff-ff00-835a-87ff-f05b20d85dc0", "PrivateSubnet:view", "ttzzzzzzzz021gzzz0ps0v1ew1"],
        ["ffffffff-ff00-835a-802d-903015ab99a0", "PrivateSubnet:connect", "ttzzzzzzzz021g0ps0c0nnect1"],
        ["ffffffff-ff00-835a-802d-903439602b50", "PrivateSubnet:disconnect", "ttzzzzzzzz021g0ps0d1sc0nn0"],
        ["ffffffff-ff00-835a-87c0-fe019872b4e0", "Firewall:create", "ttzzzzzzzz021gz0fw0create0"],
        ["ffffffff-ff00-835a-87c0-fe01ae0bb4e0", "Firewall:delete", "ttzzzzzzzz021gz0fw0de1ete1"],
        ["ffffffff-ff00-835a-87ff-f03f807343a0", "Firewall:edit", "ttzzzzzzzz021gzzz0fw0ed1t1"],
        ["ffffffff-ff00-835a-87ff-f03f80d85dc0", "Firewall:view", "ttzzzzzzzz021gzzz0fw0v1ew0"],
        ["ffffffff-ff00-835a-87c0-15819872b4e0", "LoadBalancer:create", "ttzzzzzzzz021gz01b0create1"],
        ["ffffffff-ff00-835a-87c0-1581ae0bb4e0", "LoadBalancer:delete", "ttzzzzzzzz021gz01b0de1ete0"],
        ["ffffffff-ff00-835a-87ff-f005607343a0", "LoadBalancer:edit", "ttzzzzzzzz021gzzz01b0ed1t0"],
        ["ffffffff-ff00-835a-87ff-f00560d85dc0", "LoadBalancer:view", "ttzzzzzzzz021gzzz01b0v1ew1"],
        ["ffffffff-ff00-835a-87c1-68019872b4e0", "Postgres:create", "ttzzzzzzzz021gz0pg0create1"],
        ["ffffffff-ff00-835a-87c1-6801ae0bb4e0", "Postgres:delete", "ttzzzzzzzz021gz0pg0de1ete0"],
        ["ffffffff-ff00-835a-87ff-f05a007343a0", "Postgres:edit", "ttzzzzzzzz021gzzz0pg0ed1t0"],
        ["ffffffff-ff00-835a-87ff-f05a00d85dc0", "Postgres:view", "ttzzzzzzzz021gzzz0pg0v1ew1"],
        ["ffffffff-ff00-835a-87ff-f005c0d85dc0", "InferenceEndpoint:view", "ttzzzzzzzz021gzzz01e0v1ew1"],
        ["ffffffff-ff00-835a-87c0-1d019872b4e0", "InferenceToken:create", "ttzzzzzzzz021gz01t0create1"],
        ["ffffffff-ff00-835a-87c0-1d01ae0bb4e0", "InferenceToken:delete", "ttzzzzzzzz021gz01t0de1ete0"],
        ["ffffffff-ff00-835a-87ff-f00740d85dc0", "InferenceToken:view", "ttzzzzzzzz021gzzz01t0v1ew1"],
        ["ffffffff-ff00-835a-87ff-ff8359029ad0", "SubjectTag:add", "ttzzzzzzzz021gzzzz0ts0add1"],
        ["ffffffff-ff00-835a-87c1-ac830ea036e0", "SubjectTag:remove", "ttzzzzzzzz021gz0ts0rem0ve0"],
        ["ffffffff-ff00-835a-87ff-f06b20d85dc0", "SubjectTag:view", "ttzzzzzzzz021gzzz0ts0v1ew1"],
        ["ffffffff-ff00-835a-87ff-ff834a029ad0", "ActionTag:add", "ttzzzzzzzz021gzzzz0ta0add0"],
        ["ffffffff-ff00-835a-87c1-a5030ea036e0", "ActionTag:remove", "ttzzzzzzzz021gz0ta0rem0ve1"],
        ["ffffffff-ff00-835a-87ff-f06940d85dc0", "ActionTag:view", "ttzzzzzzzz021gzzz0ta0v1ew0"],
        ["ffffffff-ff00-835a-87ff-ff8340029ad0", "ObjectTag:add", "ttzzzzzzzz021gzzzz0t00add0"],
        ["ffffffff-ff00-835a-87c1-a0030ea036e0", "ObjectTag:remove", "ttzzzzzzzz021gz0t00rem0ve1"],
        ["ffffffff-ff00-835a-87ff-f06800d85dc0", "ObjectTag:view", "ttzzzzzzzz021gzzz0t00v1ew0"]]
            .each(&:pop))

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
      [["ffffffff-ff00-834a-87ff-ff82d2028210", "Project:all", "tazzzzzzzz021gzzzz0pj0a110"],
        ["ffffffff-ff00-834a-87ff-ff8374028210", "Vm:all", "tazzzzzzzz021gzzzz0vm0a111"],
        ["ffffffff-ff00-834a-87ff-ff82d9028210", "PrivateSubnet:all", "tazzzzzzzz021gzzzz0ps0a111"],
        ["ffffffff-ff00-834a-87ff-ff81fc028210", "Firewall:all", "tazzzzzzzz021gzzzz0fw0a110"],
        ["ffffffff-ff00-834a-87ff-ff802b028210", "LoadBalancer:all", "tazzzzzzzz021gzzzz01b0a111"],
        ["ffffffff-ff00-834a-87ff-ff82d0028210", "Postgres:all", "tazzzzzzzz021gzzzz0pg0a111"],
        ["ffffffff-ff00-834a-87ff-ff828ea2dd80", "Member", "tazzzzzzzz021gzzzz0member0"]].each(&:pop)

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
