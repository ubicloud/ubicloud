# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "postgres") do |r|
    r.get true do
      postgres_list
    end

    r.web do
      @postgres = PostgresResource.new(flavor: r.params["flavor"] || PostgresResource::Flavor::STANDARD, project_id: @project.id)
      @flavor = @postgres.flavor
      Validation.validate_postgres_flavor(@flavor)
      @has_valid_payment_method = @project.has_valid_payment_method?

      r.post true do
        check_visible_location

        forme_set(@postgres)

        # Ideally, we would keep the default of location_id for the parameter name,
        # and everything would work.
        # However, too much other code depends on using location as the parameter name.
        # Work around by handling the location= to location_id= in the model,
        # and this code to remove the incorrect validation that forme_set would use by default.
        @postgres.forme_validations.delete(:location)

        handle_validation_failure("postgres/create") do
          postgres_post
        end
      end

      r.get "create" do
        authorize("Postgres:create", @project.id)
        view "postgres/create"
      end
    end
  end
end
