# frozen_string_literal: true

UbiCli.on("mi").run_on("show") do
  desc "Show details for a machine image"

  fields = %w[id name location arch latest-version created-at versions].freeze.each(&:freeze)

  options("ubi mi (location/mi-name | mi-id) show [options]", key: :mi_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
  end
  help_option_values("Fields:", fields)

  run do |opts, cmd|
    data = sdk_object.info
    opts = opts[:mi_show]
    keys = check_fields(opts[:fields], fields, "mi show -f option", cmd)

    body = []

    each_with_dashed(underscore_keys(keys)) do |key, display_key|
      case key
      when :versions
        data[key].each_with_index do |version, i|
          body << "version " << (i + 1).to_s << ":\n"
          version.each do |vk, vv|
            body << "  " << vk.to_s.tr("_", "-") << ": " << vv.to_s << "\n"
          end
        end
      else
        body << display_key << ": " << data[key].to_s << "\n"
      end
    end

    response(body)
  end
end
