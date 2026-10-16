# frozen_string_literal: true

Sequel.migration do
  up do
    # ttzzzzzzzz021g0vm0captvre0
    from(:action_type).insert(id: "ffffffff-ff00-835a-8037-403156d6f0e0", name: "Vm:capture")

    # Add to Vm:all
    from(:applied_action_tag).insert(tag_id: "ffffffff-ff00-834a-87ff-ff8374028210", action_id: "ffffffff-ff00-835a-8037-403156d6f0e0")
  end

  down do
    from(:applied_action_tag).where(action_id: "ffffffff-ff00-835a-8037-403156d6f0e0").delete
    from(:action_type).where(id: "ffffffff-ff00-835a-8037-403156d6f0e0").delete
  end
end
