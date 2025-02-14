# frozen_string_literal: true

UbiRodish.on("pg").run_on("show") do
  fields = %w[id name state location vm_size storage_size_gib version ha_type flavor connection_string primary earliest_restore_time firewall_rules metric_destinations ca_certificates].freeze.each(&:freeze)

  options("ubi pg location/(pg-name|_pg-ubid) show [options]", key: :pg_show) do
    on("-f", "--fields=fields", "show specific fields (default: #{fields.join(",")})")
  end

  run do |opts|
    get(project_path("location/#{@location}/postgres/#{@name}")) do |data|
      keys = fields

      if (opts = opts[:pg_show])
        keys = check_fields(opts[:fields], fields, "pg show -f option")
      end

      body = []

      keys.each do |key|
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
