# frozen_string_literal: true

class CloverWeb
  CloverBase.run_on_location :get_postgres do |project, name|
    project.postgres_resources_dataset.where { {Sequel[:postgres_resource][:server_name] => name} }.first
  end

  CloverBase.run_on_location :delete_postgres do |pg|
    pg.incr_destroy
  end

  CloverBase.run_on_location :post_postgres_restore do |project, params|
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: params["location"],
      server_name: params["name"],
      target_vm_size: params["target_vm_size"],
      target_storage_size_gib: params["target_storage_size_gib"],
      parent_id: params["parent_id"],
      restore_target: params["restore_target"]
    )
  end

  CloverBase.run_on_location :check_postgres_server_primary do |pg|
    pg.server.primary?
  end

  CloverBase.run_on_location :postgres_update_password do |pg, params|
    pg.update(superuser_password: params["original_password"])
    pg.server.incr_update_superuser_password
  end

  hash_branch(:project_location_prefix, "postgres") do |r|
    @serializer = Serializers::Web::Postgres

    r.on String do |pg_name|
      pg = get_postgres(@location, @project, pg_name)

      unless pg
        response.status = 404
        r.halt
      end
      @pg = serialize(pg, :detailed)

      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)
        view "postgres/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Postgres:delete", pg.id)
        delete_postgres(@location, pg)
        return {message: "Deleting #{pg.server_name}"}.to_json
      end

      r.post "restore" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        r.params["location"] = pg.location
        r.params["target_vm_size"] = pg.target_vm_size
        r.params["target_storage_size_gib"] = pg.target_storage_size_gib
        r.params["parent_id"] = pg.id
        st = post_postgres_restore(r.params["location"], @project, r.params)

        flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

        r.redirect "#{@project.path}#{st.subject.path}"
      end

      r.post "reset-superuser-password" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        unless check_postgres_server_primary(@location, pg)
          flash["error"] = "Superuser password cannot be updated during restore!"
          return redirect_back_with_inputs
        end

        Validation.validate_postgres_superuser_password(r.params["original_password"], r.params["repeat_password"])

        postgres_update_password(@location, pg, params)

        flash["notice"] = "The superuser password will be updated in a few seconds"

        r.redirect "#{@project.path}#{pg.path}"
      end
    end
  end
end
