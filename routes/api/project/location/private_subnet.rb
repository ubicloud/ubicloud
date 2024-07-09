# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    r.get true do
      result = @project.private_subnets_dataset.where(location: @location).authorized(@current_user.id, "PrivateSubnet:view").eager(nics: [:private_subnet]).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::PrivateSubnet.serialize(result[:records]),
        count: result[:count]
      }
    end

    r.on "id" do
      r.is String do |ps_id|
        ps = PrivateSubnet.from_ubid(ps_id)

        if ps&.location != @location
          ps = nil
        end

        handle_ps_requests(@current_user, ps)
      end
    end

    r.is String do |ps_name|
      r.post true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

        request_body = r.body.read
        firewall_id = unless request_body.empty?
          request_body_params = Validation.validate_request_body(request_body, [], ["firewall_id"])
          if request_body_params["firewall_id"]
            firewall_id = request_body_params["firewall_id"]
            fw = Firewall.from_ubid(firewall_id)
            unless fw && fw.location == @location
              fail Validation::ValidationFailed.new(firewall_id: "Firewall with id \"#{firewall_id}\" and location \"#{@location}\" is not found")
            end
            Authorization.authorize(@current_user.id, "Firewall:view", fw.id)
            fw.id
          end
        end

        st = Prog::Vnet::SubnetNexus.assemble(
          @project.id,
          name: ps_name,
          location: @location,
          firewall_id: firewall_id
        )

        Serializers::PrivateSubnet.serialize(st.subject)
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
      Serializers::PrivateSubnet.serialize(ps)
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
