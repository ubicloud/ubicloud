# frozen_string_literal: true

UbiCli.on("lb").run_on("create") do
  desc "Create a load balancer"
  algorithms = %w[round_robin hash_based].freeze.each(&:freeze)
  health_check_protocols = %w[http https tcp].freeze.each(&:freeze)
  stacks = %w[dual ipv4 ipv6].freeze.each(&:freeze)

  options("ubi lb location/lb-name create [options] (ps-name | ps-id) src-port dst-port", key: :lb_create) do
    on("-a", "--algorithm=alg", algorithms, "set the algorithm to use")
    on("-e", "--check-endpoint=path", "set the health check endpoint (default: #{Prog::Vnet::LoadBalancerNexus::DEFAULT_HEALTH_CHECK_ENDPOINT})")
    on("-p", "--check-protocol=proto", health_check_protocols, "set the health check protocol")
    on("-s", "--stack=stack", stacks, "set the stack")
  end
  help_option_values("Algorithm:", algorithms)
  help_option_values("Health Check Protocol:", health_check_protocols)
  help_option_values("Stack:", stacks)

  args 3

  run do |private_subnet_id, src_port, dst_port, opts, cmd|
    private_subnet_id = convert_name_to_id(sdk.private_subnet, private_subnet_id)
    params = underscore_keys(opts[:lb_create])
    if (endpoint = params.delete(:check_endpoint))
      params[:health_check_endpoint] = endpoint
    end
    params[:health_check_protocol] = params.delete(:check_protocol)
    params[:private_subnet_id] = private_subnet_id
    params[:src_port] = need_integer_arg(src_port, "src-port", cmd)
    params[:dst_port] = need_integer_arg(dst_port, "dst-port", cmd)
    id = sdk.load_balancer.create(location: @location, name: @name, **params).id
    response("Load balancer created with id: #{id}")
  end
end
