# frozen_string_literal: true

UbiRodish.on("vm") do
  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/vm")
    autoload_post_subcommand_dir("cli-commands/vm/post")
  end
  # :nocov:

  args(3...)

  run do |(location, vm_name, *argv), opts, command|
    @location = location
    @vm_name = vm_name
    command.run(self, opts, argv)
  end
end
