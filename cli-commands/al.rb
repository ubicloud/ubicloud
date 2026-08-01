# frozen_string_literal: true

class UbiCli
  on("al") do
    desc "View project audit log"

    banner "ubi al command [...]"

    # simplecov:disable
    unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
      autoload_subcommand_dir("cli-commands/al")
    end
    # simplecov:enable
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/al")
