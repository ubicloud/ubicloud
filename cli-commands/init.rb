# frozen_string_literal: true

UbiCli.on("init") do
  desc "Manage init scripts"

  banner "ubi init command [...]"

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/init")
  end
  # :nocov:
end

Unreloader.record_dependency(__FILE__, "cli-commands/init")
