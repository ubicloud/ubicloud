# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    ps_endpoint_helper = Routes::Common::PrivateSubnetHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get true do
      ps_endpoint_helper.list
    end

    r.on NAME_OR_UBID do |ps_name, ps_id|
      if ps_name
        r.post true do
          ps_endpoint_helper.post(ps_name)
        end

        filter = {Sequel[:private_subnet][:name] => ps_name}
      else
        filter = {Sequel[:private_subnet][:id] => UBID.to_uuid(ps_id)}
      end

      filter[:location] = @location
      ps = @project.private_subnets_dataset.first(filter)
      ps_endpoint_helper.instance_variable_set(:@resource, ps)
      handle_ps_requests(ps_endpoint_helper)
    end

    # 204 response for invalid names
    r.is String do |ps_name|
      r.post do
        ps_endpoint_helper.post(ps_name)
      end

      r.delete do
        response.status = 204
        nil
      end
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
