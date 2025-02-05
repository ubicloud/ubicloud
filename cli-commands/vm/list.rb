# frozen_string_literal: true

UbiRodish.on("vm", "list") do
  options("ubi vm list [options]", key: :vm_list) do
    on("-N", "--no-headers", "do not show headers")
    on("-i", "--id", "show id")
    on("-n", "--name", "show name")
    on("-l", "--location", "show location")
    on("-4", "--ip4", "show IPv4 address")
    on("-6", "--ip6", "show IPv6 address")
  end

  fields = %w[location name id ip4 ip6].freeze.each(&:freeze)

  run do |opts|
    get(project_path("vm")) do |data|
      keys = fields
      headers = true
      if (opts = opts[:vm_list])
        keys = keys.select { opts[_1.to_sym] }
        keys = fields if keys.empty?
        headers = false if opts[:"no-headers"] == false
      end

      format_rows(keys, data["items"], headers:)
    end
  end
end
