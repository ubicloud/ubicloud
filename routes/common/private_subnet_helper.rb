# frozen_string_literal: true

class Routes::Common::PrivateSubnetHelper < Routes::Common::Base
  def post(name)
    Authorization.authorize(@user.id, "PrivateSubnet:create", project.id)

    unless params.empty?
      required_parameters = []
      required_parameters << "name" << "location" if @mode == AppMode::WEB
      request_body_params = Validation.validate_request_body(params, required_parameters, ["firewall_id"])
      firewall_id = if request_body_params["firewall_id"]
        fw = Firewall.from_ubid(request_body_params["firewall_id"])
        unless fw && fw.location == @location
          fail Validation::ValidationFailed.new(firewall_id: "Firewall with id \"#{request_body_params["firewall_id"]}\" and location \"#{@location}\" is not found")
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

    if @mode == AppMode::API
      Serializers::PrivateSubnet.serialize(st.subject)
    else
      flash["notice"] = "'#{@request.params["name"]}' will be ready in a few seconds"
      @request.redirect "#{project.path}#{PrivateSubnet[st.id].path}"
    end
  end
end
