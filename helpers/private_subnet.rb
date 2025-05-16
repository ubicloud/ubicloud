# frozen_string_literal: true

class Clover
  def authorized_private_subnet(perm: "PrivateSubnet:view", location_id: nil, key: "private_subnet_id", id: nil)
    authorized_object(association: :private_subnets, key:, perm:, location_id:, id:)
  end

  def private_subnet_list
    dataset = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view")

    if api?
      dataset = dataset.where(location: @location) if @location
      paginated_result(dataset.eager(nics: :private_subnet), Serializers::PrivateSubnet)
    else
      @pss = Serializers::PrivateSubnet.serialize(dataset.all, {include_path: true})
      view "networking/private_subnet/index"
    end
  end

  def private_subnet_post(name)
    authorize("PrivateSubnet:create", @project.id)

    if (firewall_id = typecast_params.nonempty_str("firewall_id"))
      unless (firewall = authorized_firewall(location_id: @location.id))
        fail Validation::ValidationFailed.new(firewall_id: "Firewall with id \"#{firewall_id}\" and location \"#{@location.display_name}\" is not found")
      end
    end

    ps = nil
    DB.transaction do
      ps = Prog::Vnet::SubnetNexus.assemble(
        @project.id,
        name:,
        location_id: @location.id,
        firewall_id: firewall&.id
      ).subject
      audit_log(ps, "create")
    end

    if api?
      Serializers::PrivateSubnet.serialize(ps)
    else
      flash["notice"] = "'#{name}' will be ready in a few seconds"
      request.redirect "#{@project.path}#{ps.path}"
    end
  end

  def generate_private_subnet_options
    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.locations)
    options.serialize
  end
end
