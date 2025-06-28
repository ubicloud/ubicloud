# frozen_string_literal: true

UbiCli.on("vm").run_on("show") do
  desc "Show details for a virtual machine"

  fields = %w[id name state location size unix-user storage-size-gib ip6 ip4-enabled ip4 private-ipv4 private-ipv6 subnet firewalls].freeze.each(&:freeze)
  firewall_fields = %w[id name description location path firewall-rules].freeze.each(&:freeze)
  firewall_rule_fields = %w[id cidr port-range].freeze.each(&:freeze)

  options("ubi vm (location/vm-name | vm-id) show [options]", key: :vm_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-r", "--rule-fields=fields", "show specific firewall rule fields (comma separated)")
    on("-w", "--firewall-fields=fields", "show specific firewall fields (comma separated)")
  end
  help_option_values("Fields:", fields)
  help_option_values("Firewall Rule Fields:", firewall_rule_fields)
  help_option_values("Firewall Fields:", firewall_fields)

  run do |opts, cmd|
    data = sdk_object.info
    opts = opts[:vm_show]
    keys = check_fields(opts[:fields], fields, "vm show -f option", cmd)
    firewall_keys = check_fields(opts[:"firewall-fields"], firewall_fields, "vm show -w option", cmd)
    firewall_rule_keys = check_fields(opts[:"rule-fields"], firewall_rule_fields, "vm show -r option", cmd)

    body = []

    firewall_keys = underscore_keys(firewall_keys)
    firewall_rule_keys = underscore_keys(firewall_rule_keys)
    underscore_keys(keys).each do |key|
      case key
      when :firewalls
        data[key].each_with_index do |firewall, i|
          body << "firewall " << (i + 1).to_s << ":\n"
          firewall_keys.each do |fw_key|
            if fw_key == :firewall_rules
              body << "  rules:\n"
              firewall[fw_key].each_with_index do |rule, i|
                body << "    " << (i + 1).to_s << ": "
                firewall_rule_keys.each do |fwr_key|
                  body << rule[fwr_key].to_s << "  "
                end
                body << "\n"
              end
            else
              body << "  " << fw_key.to_s << ": " << firewall[fw_key].to_s << "\n"
            end
          end
        end
      when :subnet
        body << key.to_s << ": " << data[key].name << "\n"
      else
        body << key.to_s << ": " << data[key].to_s << "\n"
      end
    end

    response(body)
  end
end
