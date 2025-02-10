# frozen_string_literal: true

UbiRodish.on("pg") do
  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/pg")
    autoload_post_subcommand_dir("cli-commands/pg/post")
  end
  # :nocov:

  args(2...)

  run do |(pg_ref, *argv), opts, command|
    @location, @pg_name, extra = pg_ref.split("/", 3)
    raise Rodish::CommandFailure, "invalid pg reference, should be in location/(pg-name|_pg-ubid) format" if extra
    command.run(self, opts, argv)
  end
end
