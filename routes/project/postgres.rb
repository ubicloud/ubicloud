# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "postgres") do |r|
    r.get true do
      tags_param = typecast_params.nonempty_str("tags")
      postgres_list(tags_param:)
    end

    r.get "locations" do
      authorize("Postgres:view", @project)
      {items: Serializers::PostgresLocation.serialize(vm_families_for_project(@project))}
    end

    r.web do
      r.post true do
        handle_validation_failure("postgres/create")
        @location ||= Location[typecast_params.ubid_uuid("location")]
        postgres_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("Postgres:create", @project)
        view "postgres/create"
      end
    end
  end
end
