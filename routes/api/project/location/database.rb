# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "database") do |r|
    @serializer = Serializers::Api::Postgres

    r.get true do
      # For now only Postgres is supported
      result = @project.postgres_resources_dataset.where(location: @location).authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
        cursor: r.params["cursor"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.hash_branches(:project_location_database_prefix)
  end
end
