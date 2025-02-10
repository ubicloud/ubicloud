# frozen_string_literal: true

UbiRodish.on("pg", "list") do
  fields = %w[location name id version flavor].freeze.each(&:freeze)

  options("ubi pg list [options]", key: :pg_list) do
    on("-f", "--fields=fields", "show specific fields (default: #{fields.join(",")})")
    on("-l", "--location=location", "only show PostgreSQL databases in given location")
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    pg_opts = opts[:pg_list]
    path = if pg_opts && (location = pg_opts[:location])
      if LocationNameConverter.to_internal_name(location)
        "location/#{location}/postgres"
      else
        raise Rodish::CommandFailure, "invalid location provided in pg list -l option"
      end
    else
      "postgres"
    end

    get(project_path(path)) do |data|
      keys = fields
      headers = true

      if (opts = opts[:pg_list])
        keys = check_fields(opts[:fields], fields, "pg list -f option")
        headers = false if opts[:"no-headers"] == false
      end

      format_rows(keys, data["items"], headers:)
    end
  end
end
