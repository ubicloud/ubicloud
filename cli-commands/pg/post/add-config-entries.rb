# frozen_string_literal: true

UbiCli.on("pg").run_on("add-config-entries") do
  desc "Add configuration entries to a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) add-config-entries key=value [...]"

  args(1..)

  run do |args, _, cmd|
    body = ["Updated config:\n"]

    values = args.to_h do
      if it.include?("=")
        it.split("=", 2)
      else
        raise Rodish::CommandFailure.new("invalid add-config-entries argument, does not include `=`: #{it.inspect}", cmd)
      end
    end

    sdk_object.update_config(**values).sort.each do |k, v|
      body << k.to_s << "=" << v.to_s << "\n"
    end
    response(body)
  end
end
