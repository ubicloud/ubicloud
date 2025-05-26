# frozen_string_literal: true

class Clover
  def authorized_firewall(perm: "Firewall:view", location_id: nil)
    authorized_object(association: :firewalls, key: "firewall_id", perm:, location_id:)
  end

  def firewall_list_dataset
    dataset_authorize(@project.firewalls_dataset, "Firewall:view")
  end

  def firewall_list_api_response(dataset)
    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset.eager(:firewall_rules), Serializers::Firewall)
  end

  def firewall_post(firewall_name)
    authorize("Firewall:create", @project.id)
    Validation.validate_name(firewall_name)

    description = typecast_params.str("description") || ""

    firewall = nil
    DB.transaction do
      firewall = Firewall.create_with_id(
        name: firewall_name,
        description:,
        location_id: @location.id,
        project_id: @project.id
      )
      audit_log(firewall, "create")
    end

    if api?
      Serializers::Firewall.serialize(firewall)
    else
      if (private_subnet = authorized_private_subnet(perm: "PrivateSubnet:edit", location_id: @location.id))
        firewall.associate_with_private_subnet(private_subnet)
      end

      flash["notice"] = "'#{firewall_name}' is created"
      request.redirect "#{@project.path}#{firewall.path}"
    end
  end

  def generate_firewall_options
    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "description")
    options.add_option(name: "location", values: Option.locations)
    subnets = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").map {
      {
        location_id: it.location_id,
        value: it.ubid,
        display_name: it.name
      }
    }
    options.add_option(name: "private_subnet_id", values: subnets, parent: "location", check: ->(location, private_subnet) {
      private_subnet[:location_id] == location.id
    })
    options.serialize
  end
end
