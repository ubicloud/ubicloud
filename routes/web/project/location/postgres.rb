# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "postgres") do |r|
    unless @project.get_enable_postgres
      response.status = 404
      r.halt
    end

    @serializer = Serializers::Web::Postgres

    r.on String do |pg_name|
      pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:server_name] => pg_name} }.first

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
        pg.incr_destroy
        return {message: "Deleting #{pg.server_name}"}.to_json
      end

      r.post "restore" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        st = Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: @project.id,
          location: pg.location,
          server_name: r.params["name"],
          target_vm_size: pg.target_vm_size,
          target_storage_size_gib: pg.target_storage_size_gib,
          parent_id: pg.id,
          restore_target: r.params["restore_target"]
        )

        flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

        r.redirect "#{@project.path}#{st.subject.path}"
      end
    end
  end
end
