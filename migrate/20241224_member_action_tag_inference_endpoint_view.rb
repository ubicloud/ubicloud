# frozen_string_literal: true

Sequel.migration do
  up do
    # member global action tag includes InferenceEndpoint:view
    DB[:applied_action_tag].insert(tag_id: "ffffffff-ff00-834a-87ff-ff828ea2dd80", action_id: "ffffffff-ff00-835a-87ff-f005c0d85dc0")
  end

  down do
    DB[:applied_action_tag].where(tag_id: "ffffffff-ff00-834a-87ff-ff828ea2dd80", action_id: "ffffffff-ff00-835a-87ff-f005c0d85dc0").delete
  end
end
