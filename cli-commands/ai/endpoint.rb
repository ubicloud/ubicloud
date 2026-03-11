# frozen_string_literal: true

UbiCli.on("ai", "endpoint") do
  desc "Manage AI inference endpoints"

  banner "ubi ai endpoint [command] ..."

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/ai/endpoint")
  end
  # :nocov:
end

Unreloader.record_dependency(__FILE__, "cli-commands/ai/endpoint")
