# frozen_string_literal: true

UbiCli.on("ps").run_on("show") do
  desc "Show details for a private subnet"

  fields = %w[id name state location net4 net6 firewalls nics].freeze.each(&:freeze)
  firewall_fields = %w[id name description location path firewall-rules].freeze.each(&:freeze)
  firewall_rule_fields = %w[id cidr port-range].freeze.each(&:freeze)
  nic_fields = %w[id name private-ipv4 private-ipv6 vm-name].freeze.each(&:freeze)

  options("ubi ps (location/ps-name | ps-id) show [options]", key: :ps_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-n", "--nic-fields=fields", "show specific nic fields (comma separated)")
    on("-r", "--rule-fields=fields", "show specific firewall rule fields (comma separated)")
    on("-w", "--firewall-fields=fields", "show specific firewall fields (comma separated)")
  end
  help_option_values("Fields:", fields)
  help_option_values("Nic Fields:", nic_fields)
  help_option_values("Firewall Rule Fields:", firewall_rule_fields)
  help_option_values("Firewall Fields:", firewall_fields)

  run do |opts, cmd|
    data = sdk_object.info
    opts = opts[:ps_show]
    keys = underscore_keys(check_fields(opts[:fields], fields, "ps show -f option", cmd))
    firewall_keys = underscore_keys(check_fields(opts[:"firewall-fields"], firewall_fields, "ps show -w option", cmd))
    firewall_rule_keys = underscore_keys(check_fields(opts[:"rule-fields"], firewall_rule_fields, "ps show -r option", cmd))
    nic_keys = underscore_keys(check_fields(opts[:"nic-fields"], nic_fields, "ps show -n option", cmd))

    body = []

    keys.each do |key|
      case key
      when :firewalls
        data[key].each_with_index do |firewall, i|
          body << "firewall " << (i + 1).to_s << ":\n"
          firewall_keys.each do |fw_key|
            if fw_key == :firewall_rules
              body << "  rules:\n"
              firewall[fw_key].each_with_index do |rule, i|
                body << "   " << (i + 1).to_s << ": "
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
      when :nics
        data[key].each_with_index do |nic, i|
          body << "nic " << (i + 1).to_s << ":\n"
          nic_keys.each do |nic_key|
            body << "  " << nic_key.to_s << ": " << nic[nic_key].to_s << "\n"
          end
        end
      else
        body << key.to_s << ": " << data[key].to_s << "\n"
      end
    end

    response(body)
  end
end
