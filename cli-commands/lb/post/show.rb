# frozen_string_literal: true

UbiCli.on("lb").run_on("show") do
  desc "Show details for a load balancer"

  fields = %w[id name state location hostname algorithm stack health-check-endpoint health-check-protocol src-port dst-port subnet vms].freeze.each(&:freeze)

  options("ubi lb (location/lb-name | lb-id) show [options]", key: :lb_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
  end
  help_option_values("Fields:", fields)

  run do |opts, cmd|
    data = sdk_object.info
    keys = underscore_keys(check_fields(opts[:lb_show][:fields], fields, "lb show -f option", cmd))

    body = []

    keys.each do |key|
      case key
      when :vms
        body << "vms:\n"
        data[key].each do |vm|
          body << "  " << vm.id << "\n"
        end
      when :subnet
        body << key.to_s << ": " << data.subnet.name << "\n"
      else
        body << key.to_s << ": " << data[key].to_s << "\n"
      end
    end

    response(body)
  end
end
