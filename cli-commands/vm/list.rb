# frozen_string_literal: true

UbiRodish.on("vm", "list") do
  fields = %w[location name id ip4 ip6].freeze.each(&:freeze)

  options("ubi vm list [options]", key: :vm_list) do
    on("-N", "--no-headers", "do not show headers")
    on("-f", "--fields=fields", "show specific fields (default: #{fields.join(",")})")
  end

  run do |opts|
    get(project_path("vm")) do |data|
      keys = fields
      headers = true
      if (opts = opts[:vm_list])
        if opts[:fields]
          keys = opts[:fields].split(",")
          if keys.empty?
            raise Rodish::CommandFailure, "no fields given in vm list -f option"
          end
          unless keys.size == keys.uniq.size
            raise Rodish::CommandFailure, "duplicate field(s) in vm list -f option"
          end

          invalid_keys = keys - fields
          unless invalid_keys.empty?
            raise Rodish::CommandFailure, "invalid field(s) given vm list -f option: #{invalid_keys.join(",")}"
          end
        end

        headers = false if opts[:"no-headers"] == false
      end

      format_rows(keys, data["items"], headers:)
    end
  end
end
