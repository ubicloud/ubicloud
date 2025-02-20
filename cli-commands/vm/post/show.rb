# frozen_string_literal: true

UbiCli.on("vm").run_on("show") do
  fields = %w[id name state location size unix-user storage-size-gib ip6 ip4-enabled ip4 private-ipv4 private-ipv6 subnet firewalls].freeze.each(&:freeze)
  firewall_fields = %w[id name description location path firewall-rules].freeze.each(&:freeze)
  firewall_rule_fields = %w[id cidr port-range].freeze.each(&:freeze)

  options("ubi vm location/(vm-name|_vm-ubid) show [options]", key: :vm_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-r", "--rule-fields=fields", "show specific firewall rule fields (comma separated)")
    on("-w", "--firewall-fields=fields", "show specific firewall fields (comma separated)")
    wrap("Fields:", fields)
    wrap("Firewall Rule Fields:", firewall_rule_fields)
    wrap("Firewall Fields:", firewall_fields)
  end

  run do |opts|
    get(vm_path) do |data|
      opts = opts[:vm_show]
      keys = check_fields(opts[:fields], fields, "vm show -f option")
      firewall_keys = check_fields(opts[:"firewall-fields"], firewall_fields, "vm show -w option")
      firewall_rule_keys = check_fields(opts[:"rule-fields"], firewall_rule_fields, "vm show -r option")

      body = []

      firewall_keys = underscore_keys(firewall_keys)
      firewall_rule_keys = underscore_keys(firewall_rule_keys)
      underscore_keys(keys).each do |key|
        if key == "firewalls"
          data[key].each_with_index do |firewall, i|
            body << "firewall " << (i + 1).to_s << ":\n"
            firewall_keys.each do |fw_key|
              if fw_key == "firewall_rules"
                body << "  rules:\n"
                firewall[fw_key].each_with_index do |rule, i|
                  body << "    " << (i + 1).to_s << ": "
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
