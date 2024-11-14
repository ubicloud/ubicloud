# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      postgres_list
    end

    r.on web? do
      r.post true do
        pg_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
        pg_endpoint_helper.post(name: r.params["name"])
      end

      r.on "create" do
        r.get true do
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
  end

  hash_branch(:api_project_prefix, "postgres", &branch)
  hash_branch(:project_prefix, "postgres", &branch)
end
