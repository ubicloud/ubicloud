# frozen_string_literal: true

UbiRodish.on("vm").run_on("show") do
  fields = %w[id name state location size unix_user storage_size_gib ip6 ip4_enabled ip4 private_ipv4 private_ipv6 subnet firewalls].freeze.each(&:freeze)
  firewall_fields = %w[id name description location path firewall_rules].freeze.each(&:freeze)
  firewall_rule_fields = %w[id cidr port_range].freeze.each(&:freeze)

  options("ubi vm location/(vm-name|_vm-ubid) show [options]", key: :vm_show) do
    on("-f", "--fields=fields", "show specific fields (default: #{fields.join(",")})")
    on("-r", "--firewall_rule_fields=fields", "show specific fields (default: #{firewall_rule_fields.join(",")})")
    on("-w", "--firewall_fields=fields", "show specific fields (default: #{firewall_fields.join(",")})")
  end

  run do |opts|
    get(project_path("location/#{@location}/vm/#{@vm_name}")) do |data|
      keys = fields
      firewall_keys = firewall_fields
      firewall_rule_keys = firewall_rule_fields

      if (opts = opts[:vm_show])
        keys = check_fields(opts[:fields], fields, "vm show -f option")
        firewall_keys = check_fields(opts[:firewall_fields], firewall_fields, "vm show -w option")
        firewall_rule_keys = check_fields(opts[:firewall_rule_fields], firewall_rule_fields, "vm show -r option")
      end

      body = []

      keys.each do |key|
        if key == "firewalls"
          data[key].each_with_index do |firewall, i|
            body << "firewall " << (i + 1).to_s << ":\n"
            firewall_keys.each do |fw_key|
              if fw_key == "firewall_rules"
                firewall[fw_key].each_with_index do |rule, i|
                  body << "  rule " << (i + 1).to_s << ": "
                  firewall_rule_keys.each do |fwr_key|
                    body << rule[fwr_key].to_s << "  "
                  end
                  body << "\n"
                end
              else
                body << "  " << fw_key << ": " << firewall[fw_key].to_s << "\n"
              end
            end
          end
        else
          body << key << ": " << data[key].to_s << "\n"
        end
      end

      body
    end
  end
end
