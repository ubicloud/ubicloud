# frozen_string_literal: true

UbiCli.on("lb").run_on("show") do
  fields = %w[id name state location hostname algorithm stack health-check-endpoint health-check-protocol src-port dst-port subnet vms].freeze.each(&:freeze)

  options("ubi lb (location/lb-name|lb-id) show [options]", key: :lb_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    wrap("Fields:", fields)
  end

  run do |opts|
    get(lb_path) do |data|
      keys = underscore_keys(check_fields(opts[:lb_show][:fields], fields, "lb show -f option"))

      body = []

      keys.each do |key|
        if key == "vms"
          body << "vms:\n"
          data[key].each do |vm_ubid|
            body << "  " << vm_ubid << "\n"
          end
        else
          body << key << ": " << data[key].to_s << "\n"
        end
      end

      body
    end
  end
end
