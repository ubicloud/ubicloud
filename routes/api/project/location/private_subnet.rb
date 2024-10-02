# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    ps_endpoint_helper = Routes::Common::PrivateSubnetHelper.new(app: self, request: r, user: @current_user, location: @location, resource: nil)

    r.get true do
      ps_endpoint_helper.list
    end

    r.on "id" do
      r.is String do |ps_id|
        ps = PrivateSubnet.from_ubid(ps_id)

        if ps&.location != @location
          ps = nil
        end

        ps_endpoint_helper.instance_variable_set(:@resource, ps)
        handle_ps_requests(ps_endpoint_helper)
      end
    end

    r.is String do |ps_name|
      r.post true do
        ps_endpoint_helper.post(ps_name)
      end

      ps_endpoint_helper.instance_variable_set(:@resource, @project.private_subnets_dataset.where(location: @location).where { {Sequel[:private_subnet][:name] => ps_name} }.first)
      handle_ps_requests(ps_endpoint_helper)
    end
  end

  def handle_ps_requests(ps_endpoint_helper)
    unless ps_endpoint_helper.instance_variable_get(:@resource)
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      ps_endpoint_helper.get
    end

    request.delete true do
      ps_endpoint_helper.delete
    end
  end
end
