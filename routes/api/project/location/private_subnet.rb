# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    @serializer = Serializers::Api::PrivateSubnet

    r.get true do
      result = @project.private_subnets_dataset.where(location: @location).authorized(@current_user.id, "PrivateSubnet:view").eager(nics: [:private_subnet]).paginated_result(
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

    r.on "id" do
      r.is String do |ps_id|
        ps = PrivateSubnet.from_ubid(ps_id)
        handle_ps_requests(@current_user, ps)
      end
    end

    r.is String do |ps_name|
      r.post true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

        st = Prog::Vnet::SubnetNexus.assemble(
          @project.id,
          name: ps_name,
          location: @location
        )

        serialize(st.subject)
      end

      ps = @project.private_subnets_dataset.where(location: @location).where { {Sequel[:private_subnet][:name] => ps_name} }.first
      handle_ps_requests(@current_user, ps)
    end
  end

  def handle_ps_requests(user, ps)
    unless ps
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      Authorization.authorize(user.id, "PrivateSubnet:view", ps.id)
      serialize(ps)
    end

    request.delete true do
      Authorization.authorize(user.id, "PrivateSubnet:delete", ps.id)

      if ps.vms_dataset.count > 0
        fail DependencyError.new("Private subnet '#{ps.name}' has VMs attached, first, delete them.")
      end

      ps.incr_destroy
      response.status = 204
      request.halt
    end
  end
end
