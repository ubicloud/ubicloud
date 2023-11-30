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
    end
  end
end
