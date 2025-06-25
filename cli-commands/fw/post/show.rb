# frozen_string_literal: true

UbiCli.on("fw").run_on("show") do
  desc "Show details for a firewall"

  fields = %w[id name location description firewall-rules private-subnets].freeze.each(&:freeze)
  firewall_rule_fields = %w[id cidr port-range].freeze.each(&:freeze)
  private_subnet_fields = %w[id name state location net4 net6 nics].freeze.each(&:freeze)
  nic_fields = %w[id name private-ipv4 private-ipv6 vm-name].freeze.each(&:freeze)

  options("ubi fw (location/fw-name | fw-id) show [options]", key: :fw_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-n", "--nic-fields=fields", "show specific nic fields (comma separated)")
    on("-p", "--priv-subnet-fields=fields", "show specific private subnet fields (comma separated)")
    on("-r", "--rule-fields=fields", "show specific firewall rule fields (comma separated)")
  end
  help_option_values("Fields:", fields)
  help_option_values("Nic Fields:", nic_fields)
  help_option_values("Private Subnet Fields:", private_subnet_fields)
  help_option_values("Firewall Rule Fields:", firewall_rule_fields)

  run do |opts, cmd|
    data = sdk_object.info
    opts = opts[:fw_show]
    keys = underscore_keys(check_fields(opts[:fields], fields, "fw show -f option", cmd))
    firewall_rule_keys = underscore_keys(check_fields(opts[:"rule-fields"], firewall_rule_fields, "fw show -r option", cmd))
    private_subnet_keys = underscore_keys(check_fields(opts[:"priv-subnet-fields"], private_subnet_fields, "fw show -p option", cmd))
    nic_keys = underscore_keys(check_fields(opts[:"nic-fields"], nic_fields, "fw show -n option", cmd))

    body = []

    keys.each do |key|
      case key
      when :firewall_rules
        body << "rules:\n"
        data[key].each_with_index do |rule, i|
          body << "  " << (i + 1).to_s << ": "
          firewall_rule_keys.each do |fwr_key|
            body << rule[fwr_key].to_s << "  "
          end
          body << "\n"
        end
      when :private_subnets
        data[key].each_with_index do |ps, i|
          body << "private subnet " << (i + 1).to_s << ":\n"
          private_subnet_keys.each do |ps_key|
            if ps_key == :nics
              ps[ps_key].each_with_index do |nic, i|
                body << "  nic " << (i + 1).to_s << ":\n"
                nic_keys.each do |nic_key|
                  body << "    " << nic_key.to_s << ": " << nic[nic_key].to_s << "\n"
                end
              end
            else
              body << "  " << ps_key.to_s << ": " << ps[ps_key].to_s << "\n"
            end
          end
        end
      else
        body << key.to_s << ": " << data[key].to_s << "\n"
      end
    end

    response(body)
  end
end
