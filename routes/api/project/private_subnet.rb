# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "private-subnet") do |r|
    @serializer = Serializers::Api::PrivateSubnet

    # TODO: Validation
    r.get true do
      page_size = r.params["page-size"]
      cursor = r.params["cursor"]
      order_column = r.params["order-column"] ||= "id"

      result = @project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:view").order(order_column.to_sym).paginated_result(cursor, page_size, order_column)

      {
        values: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.post true do
      Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

      request_body_params = JSON.parse(request.body.read)

      st = Prog::Vnet::SubnetNexus.assemble(
        @project.id,
        name: request_body_params["name"],
        location: request_body_params["location"]
      )

      serialize(st.subject)
    end
  end
end
