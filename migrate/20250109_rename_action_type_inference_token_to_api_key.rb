# frozen_string_literal: true

Sequel.migration do
  up do
    DB[:action_type].where(id: "ffffffff-ff00-835a-87c0-1d019872b4e0").update(name: "InferenceApiKey:create")
    DB[:action_type].where(id: "ffffffff-ff00-835a-87c0-1d01ae0bb4e0").update(name: "InferenceApiKey:delete")
    DB[:action_type].where(id: "ffffffff-ff00-835a-87ff-f00740d85dc0").update(name: "InferenceApiKey:view")
  end

  down do
    DB[:action_type].where(id: "ffffffff-ff00-835a-87c0-1d019872b4e0").update(name: "InferenceToken:create")
    DB[:action_type].where(id: "ffffffff-ff00-835a-87c0-1d01ae0bb4e0").update(name: "InferenceToken:delete")
    DB[:action_type].where(id: "ffffffff-ff00-835a-87ff-f00740d85dc0").update(name: "InferenceToken:view")
  end
end
