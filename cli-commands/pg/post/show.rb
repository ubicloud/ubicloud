# frozen_string_literal: true

UbiCli.on("pg").run_on("show") do
  desc "Show details for a PostgreSQL database"

  fields = %w[id name state location vm-size storage-size-gib version ha-type flavor connection-string primary earliest-restore-time firewall-rules metric-destinations ca-certificates].freeze.each(&:freeze)

  options("ubi pg (location/pg-name | pg-id) show [options]", key: :pg_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    wrap("Fields:", fields)
  end

  run do |opts|
    get(pg_path) do |data|
      opts = opts[:pg_show]
      keys = check_fields(opts[:fields], fields, "pg show -f option")

      body = []

      underscore_keys(keys).each do |key|
        case key
        when "firewall_rules"
          body << "firewall rules:\n"
          data[key].each_with_index do |rule, i|
            body << "  " << (i + 1).to_s << ": " << rule["id"] << "  " << rule["cidr"].to_s << "\n"
          end
        when "metric_destinations"
          body << "metric destinations:\n"
          data[key].each_with_index do |md, i|
            body << "  " << (i + 1).to_s << ": " << md["id"] << "  " << md["username"].to_s << "  " << md["url"] << "\n"
          end
        when "ca_certificates"
          body << "CA certificates:\n" << data[key].to_s << "\n"
        else
          body << key << ": " << data[key].to_s << "\n"
        end
      end

      body
    end
  end
end
