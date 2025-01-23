# frozen_string_literal: true

UbiRodish.on("vm") do
  # :nocov:
  autoload_subcommand_dir("cli-commands/vm") unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
  # :nocov:
end
