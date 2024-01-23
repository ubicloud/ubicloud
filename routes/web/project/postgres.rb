# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "postgres") do |r|
    @serializer = Serializers::Web::Postgres

    r.get true do
      @postgres_databases = serialize(@project.postgres_resources_dataset.authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand, :representative_server, :timeline).all)

      view "postgres/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      parsed_size = Validation.validate_postgres_size(r.params["size"])
      st = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location: r.params["location"],
        name: r.params["name"],
        target_vm_size: parsed_size.vm_size,
        target_storage_size_gib: parsed_size.storage_size_gib
      )

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "#{@project.path}#{PostgresResource[st.id].path}"
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
