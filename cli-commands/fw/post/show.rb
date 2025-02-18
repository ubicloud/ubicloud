# frozen_string_literal: true

UbiCli.on("fw").run_on("show") do
  fields = %w[id name location description firewall-rules private-subnets].freeze.each(&:freeze)
  firewall_rule_fields = %w[id cidr port-range].freeze.each(&:freeze)
  private_subnet_fields = %w[id name state location net4 net6 nics].freeze.each(&:freeze)
  nic_fields = %w[id name private-ipv4 private-ipv6 vm-name].freeze.each(&:freeze)

  options("ubi fw location/(fw-name|_fw-ubid) show [options]", key: :fw_show) do
    on("-f", "--fields=fields", "show specific fields (default: #{fields.join(",")})")
    on("-n", "--nic-fields=fields", "show specific nic fields (default: #{nic_fields.join(",")})")
    on("-p", "--priv-subnet-fields=fields", "show specific private subnet fields (default: #{private_subnet_fields.join(",")})")
    on("-r", "--rule-fields=fields", "show specific firewall rule fields (default: #{firewall_rule_fields.join(",")})")
  end

  run do |opts|
    get(fw_path) do |data|
      opts = opts[:fw_show]
      keys = underscore_keys(check_fields(opts[:fields], fields, "fw show -f option"))
      firewall_rule_keys = underscore_keys(check_fields(opts[:"rule-fields"], firewall_rule_fields, "fw show -r option"))
      private_subnet_keys = underscore_keys(check_fields(opts[:"priv-subnet-fields"], private_subnet_fields, "fw show -p option"))
      nic_keys = underscore_keys(check_fields(opts[:"nic-fields"], nic_fields, "fw show -n option"))

      body = []

      keys.each do |key|
        case key
        when "firewall_rules"
          data[key].each_with_index do |rule, i|
            body << "rule " << (i + 1).to_s << ": "
            firewall_rule_keys.each do |fwr_key|
              body << rule[fwr_key].to_s << "  "
            end
            body << "\n"
          end
        when "private_subnets"
          data[key].each_with_index do |ps, i|
            body << "private subnet " << (i + 1).to_s << ":\n"
            private_subnet_keys.each do |ps_key|
              if ps_key == "nics"
                ps[ps_key].each_with_index do |nic, i|
                  body << "  nic " << (i + 1).to_s << ":\n"
                  nic_keys.each do |nic_key|
                    body << "    " << nic_key << ": " << nic[nic_key].to_s << "\n"
                  end
                end
              else
                body << "  " << ps_key << ": " << ps[ps_key].to_s << "\n"
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
