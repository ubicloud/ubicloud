# frozen_string_literal: true

require_relative "../ubid"

Sequel.migration do
  up do
    actions = %w[create delete edit view]
    action_ids = actions.map do |action|
      id = UBID.generate_vanity_action_type("DetachableVolume:#{action}").to_uuid
      from(:action_type).insert(id:, name: "DetachableVolume:#{action}")
      id
    end

    tag_id = UBID.generate_vanity_action_tag("DetachableVolume:all").to_uuid
    from(:action_tag).insert(id: tag_id, name: "DetachableVolume:all")

    action_ids.each do |action_id|
      from(:applied_action_tag).insert(tag_id:, action_id:)
    end

    member_tag_id = UBID.generate_vanity_action_tag("Member").to_uuid
    from(:applied_action_tag).insert(tag_id: member_tag_id, action_id: tag_id)
  end

  down do
    tag_id = UBID.generate_vanity_action_tag("DetachableVolume:all").to_uuid
    member_tag_id = UBID.generate_vanity_action_tag("Member").to_uuid
    from(:applied_action_tag).where(tag_id: member_tag_id, action_id: tag_id).delete
    from(:applied_action_tag).where(tag_id: tag_id).delete
    from(:action_tag).where(id: tag_id).delete
    from(:action_type).where(Sequel.like(:name, "DetachableVolume:%")).delete
  end
end
