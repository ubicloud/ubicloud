# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "postgres") do |r|
    r.on "capabilities" do
      r.get true do
        authorize("Postgres:view", @project)
        option_tree, = PostgresResource.generate_postgres_options(@project)
        {
          option_tree: OptionTreeGenerator.stringify_tree(option_tree),
          metadata: postgres_option_metadata(option_tree),
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
        # One product, two shapes. The chooser is the default so that neither
        # is buried: dedicated is what production wants, an ember is what a
        # test, a preview or a laptop wants.
        # A flavor on its own means a dedicated database: the flavor links, and
        # anything bookmarked before embers existed, still land on the form.
        flavor = typecast_params.nonempty_str("flavor")
        case typecast_params.nonempty_str("type") || (flavor && "dedicated")
        when "ember"
          authorize("PostgresEmber:create", @project)
          postgres_ember_create_options
          view "postgres/ember_create"
        when "dedicated"
          authorize("Postgres:create", @project)
          # Which flavor is a second question, worth asking only once somebody
          # has said they want a dedicated database.
          flavor ? view("postgres/create") : view("postgres/choose_flavor")
        else
          authorize("Postgres:view", @project)
          view "postgres/choose_type"
        end
      end
    end
  end
end
