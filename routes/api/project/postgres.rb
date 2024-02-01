# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "postgres") do |r|
    @serializer = Serializers::Api::Postgres

    r.get true do
      page_size = r.params["page-size"]
      cursor = r.params["cursor"]
      order_column = r.params["order-column"] ||= "id"

      result = @project.postgres_resources_dataset.authorized(@current_user.id, "Postgres:view").order(order_column.to_sym).paginated_result(cursor, page_size, order_column)

      {
        values: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      request_body_params = JSON.parse(request.body.read)

      parsed_size = Validation.validate_postgres_size(request_body_params["size"])
      st = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location: request_body_params["location"],
        name: request_body_params["name"],
        target_vm_size: parsed_size.vm_size,
        target_storage_size_gib: parsed_size.storage_size_gib
      )

      serialize(st.subject)
    end
  end
end
