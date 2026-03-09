# frozen_string_literal: true

class Serializers::AuditLog < Serializers::Base
  def self.serialize_internal(row, _options = {})
    {
      id: UBID.from_uuidish(row[:id]).to_s,
      at: row[:at].iso8601,
      action: row[:action],
      ubid_type: row[:ubid_type],
      subject_id: UBID.from_uuidish(row[:subject_id]).to_s,
      object_ids: row[:object_ids].map { UBID.from_uuidish(it).to_s }
    }
  end
end
