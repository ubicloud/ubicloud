# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get true do
      postgres_list
    end

    r.on web? do
      r.post true do
        @location = LocationNameConverter.to_internal_name(r.params["location"])
        postgres_post(r.params["name"])
      end

      r.get "create" do
        Authorization.authorize(current_account.id, "Postgres:create", @project.id)

        flavor = r.params["flavor"] || PostgresResource::Flavor::STANDARD
        Validation.validate_postgres_flavor(flavor)

        @flavor = flavor
        @prices = fetch_location_based_prices("PostgresCores", "PostgresStorage")
        @has_valid_payment_method = @project.has_valid_payment_method?
        @enabled_postgres_sizes = Option::VmSizes.select { @project.quota_available?("PostgresCores", _1.vcpu / 2) }.map(&:name)

        view "postgres/create"
      end
    end
  end

  hash_branch(:api_project_prefix, "postgres", &branch)
  hash_branch(:project_prefix, "postgres", &branch)
end
