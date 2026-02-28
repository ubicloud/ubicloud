# frozen_string_literal: true

UbiCli.on("app").run_on("create") do
  desc "Create an app process"

  options("ubi app location/app-name create [options]", key: :app_create) do
    on("-g", "--group=name", "app group name (for release/rollback scope)")
    on("-s", "--size=size", "VM size (for new VMs)")
    on("-p", "--port=src:dst", "create an LB (src:dst)")
    on("--subnet=name", "reference existing subnet")
    on("--lb=name", "reference existing load balancer")
  end

  run do |opts, cmd|
    params = underscore_keys(opts[:app_create])

    if (port = params.delete(:port))
      parts = port.split(":", 2)
      unless parts.length == 2
        raise Rodish::CommandFailure.new("invalid port format, expected src:dst (e.g., 443:3000)", cmd)
      end
      params[:src_port] = need_integer_arg(parts[0], "src-port", cmd)
      params[:dst_port] = need_integer_arg(parts[1], "dst-port", cmd)
    end

    params[:group_name] = params.delete(:group) if params[:group]
    params[:vm_size] = params.delete(:size) if params[:size]
    params[:subnet_name] = params.delete(:subnet) if params[:subnet]
    params[:lb_name] = params.delete(:lb) if params[:lb]

    result = sdk.app_process.create(location: @location, name: @name, **params)
    body = ["#{result.name}  created  (group: #{result.group_name})\n"]
    body << "  subnet     #{result.subnet}\n" if result.subnet
    body << "  lb         #{result.load_balancer}\n" if result.load_balancer
    response(body)
  end
end
