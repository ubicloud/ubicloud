# frozen_string_literal: true

class Routes::Common::PrivateSubnetHelper < Routes::Common::Base
  def list
    if @mode == AppMode::API
      dataset = project.private_subnets_dataset
      dataset = dataset.where(location: @location) if @location
      result = dataset.authorized(@user.id, "PrivateSubnet:view").eager(nics: [:private_subnet]).paginated_result(
        start_after: @request.params["start_after"],
        page_size: @request.params["page_size"],
        order_column: @request.params["order_column"]
      )

      {
        items: Serializers::PrivateSubnet.serialize(result[:records]),
        count: result[:count]
      }
    else
      pss = Serializers::PrivateSubnet.serialize(project.private_subnets_dataset.authorized(@user.id, "PrivateSubnet:view").all, {include_path: true})
      @app.instance_variable_set(:@pss, pss)

      @app.view "networking/private_subnet/index"
    end
  end

  def post(name)
    Authorization.authorize(@user.id, "PrivateSubnet:create", project.id)
    if @mode == AppMode::API
      firewall_id = unless params.empty?
        request_body_params = Validation.validate_request_body(params, [], ["firewall_id"])
        if request_body_params["firewall_id"]
          firewall_id = request_body_params["firewall_id"]
          fw = Firewall.from_ubid(firewall_id)
          unless fw && fw.location == @location
            fail Validation::ValidationFailed.new(firewall_id: "Firewall with id \"#{firewall_id}\" and location \"#{@location}\" is not found")
          end
          Authorization.authorize(@user.id, "Firewall:view", fw.id)
          fw.id
        end
      end

      st = Prog::Vnet::SubnetNexus.assemble(
        project.id,
        name: name,
        location: @location,
        firewall_id: firewall_id
      )

      Serializers::PrivateSubnet.serialize(st.subject)
    else
      location = LocationNameConverter.to_internal_name(@request.params["location"])

      st = Prog::Vnet::SubnetNexus.assemble(
        project.id,
        name: @request.params["name"],
        location: location
      )

      flash["notice"] = "'#{@request.params["name"]}' will be ready in a few seconds"

      @request.redirect "#{project.path}#{PrivateSubnet[st.id].path}"
    end
  end

  def get
    Authorization.authorize(@user.id, "PrivateSubnet:view", @resource.id)
    if @mode == AppMode::API
      Serializers::PrivateSubnet.serialize(@resource)
    else
      @app.instance_variable_set(:@ps, Serializers::PrivateSubnet.serialize(@resource))
      @app.instance_variable_set(:@nics, Serializers::Nic.serialize(@resource.nics))
      @app.view "networking/private_subnet/show"
    end
  end

  def delete
    Authorization.authorize(@user.id, "PrivateSubnet:delete", @resource.id)
    if @mode == AppMode::API
      if @resource.vms_dataset.count > 0
        fail DependencyError.new("Private subnet '#{@resource.name}' has VMs attached, first, delete them.")
      end

      @resource.incr_destroy
      response.status = 204
      @request.halt
    else
      if @resource.vms_dataset.count > 0
        response.status = 400
        return {message: "Private subnet has VMs attached, first, delete them."}.to_json
      end

      @resource.incr_destroy

      {message: "Deleting #{@resource.name}"}.to_json
    end
  end

  def get_create
    Authorization.authorize(@user.id, "PrivateSubnet:create", project.id)
    @app.view "networking/private_subnet/create"
  end
end
