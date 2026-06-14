# frozen_string_literal: true

Sequel.migration do
  up do
    # Action Type UUID primary keys created via:
    # UBID.generate_vanity_action_type(action).to_uuid
    # The trailing element shows the generated UBID, and is popped before inserting.
    from(:action_type).import([:id, :name],
      [["ffffffff-ff00-835a-87c1-9c819872b4e0", "SecretStore:create", "ttzzzzzzzz021gz0ss0create1"],
        ["ffffffff-ff00-835a-87ff-f06720d85dc0", "SecretStore:view", "ttzzzzzzzz021gzzz0ss0v1ew1"],
        ["ffffffff-ff00-835a-87ff-f067207343a0", "SecretStore:edit", "ttzzzzzzzz021gzzz0ss0ed1t0"],
        ["ffffffff-ff00-835a-87c1-9c81ae0bb4e0", "SecretStore:delete", "ttzzzzzzzz021gz0ss0de1ete0"]]
          .each(&:pop))

    # Action Tag UUID primary key created via:
    # UBID.generate_vanity_action_tag("SecretStore:all").to_uuid => tazzzzzzzz021gzzzz0ss0a111
    secret_store_all_id = "ffffffff-ff00-834a-87ff-ff8339028210"
    from(:action_tag).insert(id: secret_store_all_id, name: "SecretStore:all")
    from(:applied_action_tag).insert([:tag_id, :action_id],
      from(:action_type)
        .where(Sequel.like(:name, "SecretStore:%"))
        .select(Sequel.cast(secret_store_all_id, :uuid), :id))
  end

  down do
    secret_store_all_id = "ffffffff-ff00-834a-87ff-ff8339028210"
    from(:applied_action_tag).where(tag_id: secret_store_all_id).delete
    from(:action_tag).where(id: secret_store_all_id).delete
    from(:action_type).where(Sequel.like(:name, "SecretStore:%")).delete
  end
end
