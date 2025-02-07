# frozen_string_literal: true

UbiRodish.on("vm") do
  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/vm")
    autoload_post_subcommand_dir("cli-commands/vm/post")
  end
  # :nocov:

  args(2...)

  post_options("ubi vm location-name/(vm-name|_vm-ubid) [options] subcommand [...]", key: :vm_ssh) do
    on("-4", "--ip4", "use IPv4 address")
    on("-6", "--ip6", "use IPv6 address")
    on("-u", "--user user", "override username")
  end

  run do |(vm_ref, *argv), opts, command|
    @location, @vm_name, extra = vm_ref.split("/", 3)
    raise Rodish::CommandFailure, "invalid vm reference, should be in location/(vm-name|_vm-ubid) format" if extra
    command.run(self, opts, argv)
  end
end
