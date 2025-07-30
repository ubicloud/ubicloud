# frozen_string_literal: true

UbiCli.on("kc").run_on("show") do
  desc "Show details for a Kubernetes cluster"

  fields = %w[id name location display-state cp-node-count node-size version nodepools cp-vms].freeze.each(&:freeze)
  nodepool_fields = %w[id name node-count node-size vms].freeze.each(&:freeze)
  vm_fields = %w[id name state location size unix-user storage-size-gib ip6 ip4-enabled ip4].freeze.each(&:freeze)

  options("ubi kc (location/kc-name | kc-id) show [options]", key: :kc_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-n", "--nodepool-fields=fields", "show specific nodepool fields (comma separated)")
    on("-v", "--vm-fields=fields", "show specific virtual machine fields (comma separated)")
  end
  help_option_values("Fields:", fields)
  help_option_values("Nodepool Fields:", nodepool_fields)
  help_option_values("Virtual Machine Fields:", vm_fields)

  run do |opts, cmd|
    data = sdk_object.info
    opts = opts[:kc_show]
    keys = underscore_keys(check_fields(opts[:fields], fields, "kc show -f option", cmd))
    nodepool_keys = underscore_keys(check_fields(opts[:"nodepool-fields"], nodepool_fields, "kc show -n option", cmd))
    vm_keys = underscore_keys(check_fields(opts[:"vm-fields"], vm_fields, "kc show -v option", cmd))

    body = []

    keys.each do |key|
      case key
      when :nodepools
        data[key].each_with_index do |nodepool, i|
          body << "nodepool " << (i + 1).to_s << ":\n"
          nodepool_keys.each do |np_key|
            if np_key == :vms
              nodepool[np_key].each_with_index do |vm, i|
                body << "  vm " << (i + 1).to_s << ":\n"
                vm_keys.each do |vm_key|
                  body << "    " << vm_key.to_s << ": " << vm[vm_key].to_s << "\n"
                end
              end
            else
              body << "  " << np_key.to_s << ": " << nodepool[np_key].to_s << "\n"
            end
          end
        end
      when :cp_vms
        data[key].each_with_index do |vm, i|
          body << "cp vm " << (i + 1).to_s << ":\n"
          vm_keys.each do |vm_key|
            body << "  " << vm_key.to_s << ": " << vm[vm_key].to_s << "\n"
          end
        end
      else
        body << key.to_s << ": " << data[key].to_s << "\n"
      end
    end

    response(body)
  end
end
