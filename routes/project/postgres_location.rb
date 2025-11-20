# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "postgres-location") do |r|
    r.get true do
      authorize("Postgres:view", @project)
      {items: vm_families_for_project(@project).map { |l| Serializers::PostgresLocation.serialize_internal(l) }}
    end
  end
end
