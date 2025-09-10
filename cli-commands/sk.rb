# frozen_string_literal: true

UbiCli.on("sk") do
  desc "Manage SSH public keys"

  banner "ubi sk command [...]"
  post_banner "ubi sk (sk-name | sk-id) post-command [...]"

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/sk")
    autoload_post_subcommand_dir("cli-commands/sk/post")
  end
  # :nocov:

  args(2...)

  run do |(ref, *argv), opts, command|
    check_no_slash(ref, "invalid ssh public key reference (#{ref.inspect}), should not include /", command)
    @sdk_object = sdk.ssh_public_key.new(ref)
    command.run(self, opts, argv)
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/sk")
