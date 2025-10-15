# frozen_string_literal: true

class Clover
  def authorized_private_subnet(perm: "PrivateSubnet:view", location_id: nil, key: "private_subnet_id", id: nil)
    authorized_object(association: :private_subnets, key:, perm:, location_id:, id:)
  end

  def private_subnet_connection_action(type, id)
    authorize("PrivateSubnet:#{type}", @ps.id)
    handle_validation_failure("networking/private_subnet/show") { @page = "networking" }

    if type == "connect" && id == @ps.id
      raise CloverError.new(400, "InvalidRequest", "Cannot connect private subnet to itself")
    end

    if (subnet = authorized_private_subnet(perm: "PrivateSubnet:#{type}", location_id: @location.id, id:))
      name = subnet.name
    else
      raise CloverError.new(400, "InvalidRequest", "Subnet to be #{type}ed not found")
    end

    DB.transaction do
      @ps.send(:"#{type}_subnet", subnet)
      audit_log(@ps, type, subnet)
    end

    if api?
      Serializers::PrivateSubnet.serialize(@ps)
    else
      flash["notice"] = "#{name} will be #{type}ed in a few seconds"
      request.redirect @ps, "/networking"
    end
  end

  def private_subnet_list
    dataset = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view")

    if api?
      dataset = dataset.where(location: @location) if @location
      paginated_result(dataset.eager(:location, firewalls: [:location, :firewall_rules], nics: [:private_subnet, :vm]), Serializers::PrivateSubnet)
    else
      @pss = dataset.eager(:location).all
      view "networking/private_subnet/index"
    end
  end

  def private_subnet_post(name)
    authorize("PrivateSubnet:create", @project)

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
      request.redirect ps
    end
  end

  def generate_private_subnet_options
    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.locations)
    options.serialize
  end
end
