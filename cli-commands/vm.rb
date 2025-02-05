# frozen_string_literal: true

UbiRodish.on("vm") do
  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/vm")
    autoload_post_subcommand_dir("cli-commands/vm/post")
  end
  # :nocov:

  args(2...)

  run do |(vm_ref, *argv), opts, command|
    @location, @vm_name, extra = vm_ref.split("/", 3)
    raise Rodish::CommandFailure, "invalid vm reference, should be in location/(vm-name|_vm-ubid) format" if extra
    command.run(self, opts, argv)
  end
end
