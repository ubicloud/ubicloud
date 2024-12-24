# frozen_string_literal: true

class Serializers::Account < Serializers::Base
  def self.serialize_internal(a, options = {})
    base = {
      id: a.id,
      ubid: a.ubid,
      email: a.email
    }

    if (project_id = options[:project_id])
      base[:policies] = a.subject_tags_dataset.where(project_id: project_id).order_by(:name).map(&:name)
    end

    base
  end
end
