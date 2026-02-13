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
    paginated_result(dataset.eager(:firewall_rules, :location), Serializers::Firewall)
  end

  def firewall_rule_params
    if web?
      port_range = if (range = FirewallRule.range_for_port_type(typecast_params.nonempty_str("port_type")))
        "#{range.begin}..#{range.end - 1}"
      else
        start_port = typecast_params.Integer!("start_port")
        end_port = typecast_params.Integer("end_port") || start_port
        "#{start_port}..#{end_port}"
      end

      cidr = case (source_type = typecast_params.nonempty_str("source_type"))
      when "subnet4", "subnet6"
        ps_meth = (source_type == "subnet4") ? :net4 : :net6
        typecast_params.nonempty_str("fw_rule_private_subnet_id")
      when "custom"
        typecast_params.str!("cidr")
      else
        FirewallRule.cidr_for_source_type(source_type)
      end
    else
      cidr = typecast_params.str!("cidr")
      port_range = typecast_params.str("port_range")
    end

    unless cidr.include?(".") || cidr.include?(":")
      if PrivateSubnet.ubid_format.match?(cidr)
        key = :id
        value = UBID.to_uuid(cidr)
      else
        key = :name
        value = cidr
      end

      if (ps = authorized_private_subnet(:location_id => @location.id, key => value))
        cidrs = if ps_meth
          [ps.send(ps_meth)]
        else
          [ps.net4, ps.net6]
        end
      end
    end

    cidrs ||= [Validation.validate_cidr(cidr)]
    port_range = Validation.validate_port_range(port_range)
    pg_range = Sequel.pg_range(port_range.first..port_range.last)
    description = typecast_params.str("description")&.strip

    [cidrs, pg_range, description]
  end

  def firewall_post(firewall_name)
    authorize("Firewall:create", @project)
    Validation.validate_name(firewall_name)

    description = typecast_params.str("description") || ""

    firewall = nil
    DB.transaction do
      firewall = Firewall.create(
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
      request.redirect firewall
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
    options.add_option(name: "private_subnet_id", values: subnets, parent: "location") do |location, private_subnet|
      private_subnet[:location_id] == location.id
    end
    options.serialize
  end
end
