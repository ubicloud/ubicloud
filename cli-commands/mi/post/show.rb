# frozen_string_literal: true

UbiCli.on("mi").run_on("show") do
  desc "Show details for a machine image"

  fields = %w[id name location arch latest-version created-at versions].freeze.each(&:freeze)
  version_fields = %w[version id state actual-size-mib archive-size-mib created-at].freeze.each(&:freeze)

  options("ubi mi (location/mi-name | mi-id) show [options]", key: :mi_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-v", "--version-fields=fields", "show specific version fields (comma separated)")
  end
  help_option_values("Fields:", fields)
  help_option_values("Version Fields:", version_fields)

  run do |opts, cmd|
    data = sdk_object.info
    opts = opts[:mi_show]
    keys = underscore_keys(check_fields(opts[:fields], fields, "mi show -f option", cmd))
    version_keys = underscore_keys(check_fields(opts[:"version-fields"], version_fields, "mi show -v option", cmd))

    body = []

    each_with_dashed(keys) do |key, display_key|
      case key
      when :versions
        data[key].each_with_index do |version, i|
          body << "version " << (i + 1).to_s << ":\n"
          each_with_dashed(version_keys) do |v_key, display_v_key|
            body << "  " << display_v_key << ": " << version[v_key].to_s << "\n"
          end
        end
      else
        body << display_key << ": " << data[key].to_s << "\n"
      end
    end

    response(body)
  end
end
