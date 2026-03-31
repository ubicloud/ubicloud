# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "postgres") do |r|
    r.on "capabilities" do
      r.get true do
        authorize("Postgres:view", @project)
        option_tree, = PostgresResource.generate_postgres_options(@project)
        locations = Location.postgres_locations + @project.locations
        {
          option_tree: serialize_option_tree(option_tree),
          metadata: postgres_option_metadata(locations),
        }
      end
    end

    r.get true do
      tags_param = typecast_params.nonempty_str("tags")
      postgres_list(tags_param:)
    end

    r.web do
      r.post true do
        handle_validation_failure("postgres/create")
        # Skip security check to allow this, as Postgres resources perform their
        # own location validation based on option trees.
        @location ||= ::Location[typecast_params.ubid_uuid("location")]
        postgres_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("Postgres:create", @project)
        view "postgres/create"
      end
    end
  end
end
