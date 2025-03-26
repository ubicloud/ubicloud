# frozen_string_literal: true

UbiCli.on("lb").run_on("create") do
  desc "Create a load balancer"

  options("ubi lb location/lb-name create [options] ps-id src-port dst-port", key: :lb_create) do
    on("-a", "--algorithm=alg", "set the algorithm to use")
    on("-e", "--check-endpoint=path", "set the health check endpoint (default: #{Prog::Vnet::LoadBalancerNexus::DEFAULT_HEALTH_CHECK_ENDPOINT})")
    on("-p", "--check-protocol=proto", "set the health check protocol")
    on("-s", "--stack=stack", "set the stack")
  end
  help_option_values("Algorithm:", %w[round_robin hash_based])
  help_option_values("Health Check Protocol:", %w[http https tcp])
  help_option_values("Stack:", %w[dual ipv4 ipv6])

  args 3

  run do |private_subnet_id, src_port, dst_port, opts|
    params = underscore_keys(opts[:lb_create])
    if (endpoint = params.delete(:check_endpoint))
      params[:health_check_endpoint] = endpoint
    end
    params[:health_check_protocol] = params.delete(:check_protocol)
    params[:private_subnet_id] = private_subnet_id
    params[:src_port] = src_port
    params[:dst_port] = dst_port
    id = sdk.load_balancer.create(location: @location, name: @name, **params).id
    response("Load balancer created with id: #{id}")
  end
end
