# frozen_string_literal: true

class UbiCli
  on("ai", "endpoint") do
    desc "Manage AI inference endpoints"

    banner "ubi ai endpoint [command] ..."

    # simplecov:disable
    unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
      autoload_subcommand_dir("cli-commands/ai/endpoint")
    end
    # simplecov:enable
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/ai/endpoint")
