# frozen_string_literal: true

UbiCli.on("lb").run_on("create") do
  options("ubi lb location/lb-name create [options] private-subnet-id src-port dst-port", key: :lb_create) do
    on("-a", "--algorithm=alg", "set the algorithm to use (round_robin(default), hash_based)")
    on("-e", "--check-endpoint=path", "set the health check endpoint (default: #{Prog::Vnet::LoadBalancerNexus::DEFAULT_HEALTH_CHECK_ENDPOINT})")
    on("-p", "--check-protocol=proto", "set the health check protocol (http(default), https, tcp)")
    on("-s", "--stack=stack", "set the stack (dual(default), ipv4, ipv6)")
  end

  args 3

  run do |private_subnet_id, src_port, dst_port, opts|
    params = underscore_keys(opts[:lb_create])
    params["algorithm"] ||= "round_robin"
    if (endpoint = params.delete("check_endpoint"))
      params["health_check_endpoint"] = endpoint
    end
    params["health_check_protocol"] = params.delete("check_protocol") || "http"
    params["stack"] ||= "dual"
    params["private_subnet_id"] = private_subnet_id
    params["src_port"] = src_port
    params["dst_port"] = dst_port
    post(lb_path, params) do |data|
      ["Load balancer created with id: #{data["id"]}"]
    end
  end
end
