# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    @serializer = Serializers::Api::PrivateSubnet

    r.get true do
      page_size = r.params["page-size"]
      cursor = r.params["cursor"]
      order_column = r.params["order-column"] ||= "id"

      result = @project.private_subnets_dataset.where(location: @location).authorized(@current_user.id, "PrivateSubnet:view").order(order_column.to_sym).paginated_result(cursor, page_size, order_column)

      {
        values: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.on String do |ps_name|
      r.post true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

        request_body_params = JSON.parse(request.body.read)

        st = Prog::Vnet::SubnetNexus.assemble(
          @project.id,
          name: ps_name,
          location: request_body_params["location"]
        )

        serialize(st.subject)
        r.halt
      end

      ps = @project.private_subnets_dataset.where(location: @location).where { {Sequel[:private_subnet][:name] => ps_name} }.first

      r.get true do
        unless ps
          response.status = 404
          r.halt
        end

        Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps.id)

        serialize(ps)
      end

      r.delete true do
        if ps
          Authorization.authorize(@current_user.id, "PrivateSubnet:delete", ps.id)

          if ps.vms_dataset.count > 0
            fail ErrorCodes::DependencyError.new("Private subnet has VMs attached, first, delete them.")
          end

          ps.incr_destroy
        end

        response.status = 204
        r.halt
      end
    end
  end
end
