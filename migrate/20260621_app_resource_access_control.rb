# frozen_string_literal: true

Sequel.migration do
  up do
    # Action type UUIDs are generated deterministically via
    # UBID.generate_vanity_action_type("AppResource:<action>").to_uuid
    from(:action_type).import([:id, :name],
      [["ffffffff-ff00-835a-87c0-ac019872b4e0", "AppResource:create"],
        ["ffffffff-ff00-835a-87ff-f02b00d85dc0", "AppResource:view"],
        ["ffffffff-ff00-835a-87ff-f02b007343a0", "AppResource:edit"],
        ["ffffffff-ff00-835a-87c0-ac01ae0bb4e0", "AppResource:delete"]])

    # UBID.generate_vanity_action_tag("AppResource:all").to_uuid
    app_resource_all_id = "ffffffff-ff00-834a-87ff-ff8158028210"
    from(:action_tag).insert(id: app_resource_all_id, name: "AppResource:all")
    from(:applied_action_tag).insert([:tag_id, :action_id],
      from(:action_type)
        .where(Sequel.like(:name, "AppResource:%"))
        .select(Sequel.cast(app_resource_all_id, :uuid), :id))
  end

  down do
    app_resource_all_id = "ffffffff-ff00-834a-87ff-ff8158028210"
    from(:applied_action_tag).where(tag_id: app_resource_all_id).delete
    from(:action_tag).where(id: app_resource_all_id).delete
    from(:action_type).where(Sequel.like(:name, "AppResource:%")).delete
  end
end
