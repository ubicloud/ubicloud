# frozen_string_literal: true

class CloverWeb
  CloverBase.run_on_all_locations :list_postgres do |project, current_user|
    project.postgres_resources_dataset.authorized(current_user.id, "Postgres:view").eager(:semaphores, :strand, :server, :timeline).all
  end

  CloverBase.run_on_location :post_postgres do |project, params|
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: params["location"],
      server_name: params["name"],
      target_vm_size: params["vm_size"],
      target_storage_size_gib: params["storage_size_gb"]
    )
  end

  hash_branch(:project_prefix, "postgres") do |r|
    @serializer = Serializers::Web::Postgres

    r.get true do
      @postgres_databases = serialize(list_postgres(@project, @current_user))

      view "postgres/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      parsed_size = Validation.validate_postgres_size(r.params["size"])
      r.params["vm_size"] = parsed_size.vm_size
      r.params["storage_size_gb"] = parsed_size.storage_size_gib

      st = post_postgres(r.params["location"], @project, r.params)

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "#{@project.path}/postgres"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)

        @prices = fetch_location_based_prices("PostgresCores", "PostgresStorage")
        @has_valid_payment_method = @project.has_valid_payment_method?

        view "postgres/create"
      end
    end
  end
end
