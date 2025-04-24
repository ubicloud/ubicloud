# frozen_string_literal: true

UbiCli.on("ai") do
  desc "Manage AI features"

  banner "ubi ai [command] ..."

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/ai")
  end
  # :nocov:
end

Unreloader.record_dependency(__FILE__, "cli-commands/ai")
