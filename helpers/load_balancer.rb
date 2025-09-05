# frozen_string_literal: true

class Clover
  def load_balancer_list
    dataset = dataset_authorize(@project.load_balancers_dataset, "LoadBalancer:view").eager(:private_subnet)
    dataset = dataset.join(:private_subnet, id: Sequel[:load_balancer][:private_subnet_id]).where(location_id: @location.id).select_all(:load_balancer) if @location
    if api?
      paginated_result(dataset, Serializers::LoadBalancer)
    else
      @lbs = dataset.all
      view "networking/load_balancer/index"
    end
  end

  def load_balancer_post(name)
    authorize("LoadBalancer:create", @project)

    algorithm, health_check_protocol, stack = typecast_params.nonempty_str!(%w[algorithm health_check_protocol stack])
    src_port, dst_port = typecast_params.pos_int!(%w[src_port dst_port])
    health_check_endpoint = typecast_params.nonempty_str("health_check_endpoint") || Prog::Vnet::LoadBalancerNexus::DEFAULT_HEALTH_CHECK_ENDPOINT

    unless (ps = authorized_private_subnet)
      fail Validation::ValidationFailed.new("private_subnet_id" => "Private subnet not found")
    end

    lb = nil
    DB.transaction do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(
        ps.id,
        name:,
        algorithm:,
        stack: Validation.validate_load_balancer_stack(stack),
        src_port: Validation.validate_port(:src_port, src_port),
        dst_port: Validation.validate_port(:dst_port, dst_port),
        health_check_endpoint:,
        health_check_protocol:
      ).subject
      audit_log(lb, "create")
    end

    if api?
      Serializers::LoadBalancer.serialize(lb, {detailed: true})
    else
      flash["notice"] = "'#{name}' is created"
      request.redirect lb
    end
  end

  def generate_load_balancer_options
    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "description")
    options.add_option(name: "private_subnet_id", values: dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").map { {value: it.ubid, display_name: it.name} })
    options.add_option(name: "algorithm", values: ["Round Robin", "Hash Based"].map { {value: it.downcase.tr(" ", "_"), display_name: it} })
    options.add_option(name: "stack", values: [LoadBalancer::Stack::DUAL, LoadBalancer::Stack::IPV4, LoadBalancer::Stack::IPV6].map { {value: it.downcase, display_name: it.gsub("ip", "IP")} })
    options.add_option(name: "src_port")
    options.add_option(name: "dst_port")
    options.add_option(name: "health_check_endpoint")
    options.add_option(name: "health_check_protocol", values: ["http", "https", "tcp"].map { {value: it, display_name: it.upcase} })
    options.serialize
  end
end
