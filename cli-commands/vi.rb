# frozen_string_literal: true

UbiCli.on("vi") do
  desc "Manage virtual machine init scripts"

  banner "ubi vi command [...]"
  post_banner "ubi vi (vi-name | vi-id) post-command [...]"

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/vi")
    autoload_post_subcommand_dir("cli-commands/vi/post")
  end
  # :nocov:

  args(2...)

  run do |(ref, *argv), opts, command|
    check_no_slash(ref, "invalid virtual machine init script reference (#{ref.inspect}), should not include /", command)
    @sdk_object = sdk.vm_init_script.new(ref)
    command.run(self, opts, argv)
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/vi")
