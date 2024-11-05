# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    ps_endpoint_helper = Routes::Common::PrivateSubnetHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get api? do
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

      unless ps
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      if web?
        r.post "connect" do
          ps_endpoint_helper.connect(r.params["connected-subnet-ubid"])
        end

        r.post "disconnect", String do |disconnecting_ps_ubid|
          ps_endpoint_helper.disconnect(disconnecting_ps_ubid)
        end
      end

      request.get true do
        ps_endpoint_helper.get
      end

      request.delete true do
        ps_endpoint_helper.delete
      end
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

  hash_branch(:api_project_location_prefix, "private-subnet", &branch)
  hash_branch(:project_location_prefix, "private-subnet", &branch)
end
