# frozen_string_literal: true

UbiCli.on("ps").run_on("show") do
  fields = %w[id name state location net4 net6 firewalls nics].freeze.each(&:freeze)
  firewall_fields = %w[id name description location path firewall-rules].freeze.each(&:freeze)
  firewall_rule_fields = %w[id cidr port-range].freeze.each(&:freeze)
  nic_fields = %w[id name private-ipv4 private-ipv6 vm-name].freeze.each(&:freeze)

  options("ubi ps location/(ps-name|_ps-ubid) show [options]", key: :ps_show) do
    on("-f", "--fields=fields", "show specific fields (default: #{fields.join(",")})")
    on("-n", "--nic-fields=fields", "show specific nic fields (default: #{nic_fields.join(",")})")
    on("-r", "--rule-fields=fields", "show specific firewall rule fields (default: #{firewall_rule_fields.join(",")})")
    on("-w", "--firewall-fields=fields", "show specific firewall fields (default: #{firewall_fields.join(",")})")
  end

  run do |opts|
    get(ps_path) do |data|
      opts = opts[:ps_show]
      keys = underscore_keys(check_fields(opts[:fields], fields, "ps show -f option"))
      firewall_keys = underscore_keys(check_fields(opts[:"firewall-fields"], firewall_fields, "ps show -w option"))
      firewall_rule_keys = underscore_keys(check_fields(opts[:"rule-fields"], firewall_rule_fields, "ps show -r option"))
      nic_keys = underscore_keys(check_fields(opts[:"nic-fields"], nic_fields, "ps show -n option"))

      body = []

      keys.each do |key|
        case key
        when "firewalls"
          data[key].each_with_index do |firewall, i|
            body << "firewall " << (i + 1).to_s << ":\n"
            firewall_keys.each do |fw_key|
              if fw_key == "firewall_rules"
                body << "  rules:\n"
                firewall[fw_key].each_with_index do |rule, i|
                  body << "   " << (i + 1).to_s << ": "
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
        when "nics"
          data[key].each_with_index do |nic, i|
            body << "nic " << (i + 1).to_s << ":\n"
            nic_keys.each do |nic_key|
              body << "  " << nic_key << ": " << nic[nic_key].to_s << "\n"
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
