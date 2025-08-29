# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "postgres") do |r|
    r.get true do
      postgres_list
    end

    r.web do
      r.post true do
        handle_validation_failure("postgres/create")
        check_visible_location
        postgres_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("Postgres:create", @project)
        view "postgres/create"
      end
    end
  end
end
