# frozen_string_literal: true

force_autoload = Config.production? || ENV["FORCE_AUTOLOAD"] == "1"

UbiRodish = Rodish.processor do
  options("ubi [options] [subcommand [subcommand_options] ...]") do
    on("--version", "show program version") { halt "0.0.0" }
    on("--help", "show program help") { halt to_s }
    on("--confirm=confirmation", "confirmation value (not for direct use)")
  end

  # :nocov:
  autoload_subcommand_dir("cli-commands") unless force_autoload
  # :nocov:
end

Unreloader.record_dependency("lib/rodish.rb", __FILE__)
Unreloader.record_dependency("lib/ubi_cli.rb", __FILE__)
Unreloader.record_dependency(__FILE__, "cli-commands")
if force_autoload
  Unreloader.require("cli-commands") {}
# :nocov:
else
  Unreloader.autoload("cli-commands") {}
end
# :nocov:
