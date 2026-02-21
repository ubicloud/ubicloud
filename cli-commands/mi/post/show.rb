# frozen_string_literal: true

UbiCli.on("mi").run_on("show") do
  desc "Show details for a machine image"

  fields = %w[id name location state size-gib description source-vm-id created-at].freeze.each(&:freeze)

  options("ubi mi (location/mi-name | mi-id) show [options]", key: :mi_show) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
  end
  help_option_values("Fields:", fields)

  run do |opts, cmd|
    data = sdk_object.info
    opts = opts[:mi_show]
    keys = underscore_keys(check_fields(opts[:fields], fields, "mi show -f option", cmd))

    body = []

    each_with_dashed(keys) do |key, display_key|
      body << display_key << ": " << data[key].to_s << "\n"
    end

    response(body)
  end
end
