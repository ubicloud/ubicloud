# frozen_string_literal: true

UbiCli.on("jw") do
  desc "Manage trusted JWT issuers"

  banner "ubi jw command [...]"
  post_banner "ubi jw jw-id post-command [...]"

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/jw")
    autoload_post_subcommand_dir("cli-commands/jw/post")
  end
  # :nocov:

  args(2...)

  run do |(ref, *argv), opts, command|
    check_no_slash(ref, "invalid trusted JWT issuer reference (#{ref.inspect}), should not include /", command)
    @sdk_object = sdk.trusted_jwt_issuer.new(ref)
    command.run(self, opts, argv)
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/jw")
