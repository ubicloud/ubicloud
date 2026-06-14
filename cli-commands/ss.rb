# frozen_string_literal: true

class UbiCli
  on("ss") do
    desc "Manage secret stores"

    banner "ubi ss command [...]"
    post_banner "ubi ss (ss-name | ss-id) post-command [...]"

    # :nocov:
    unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
      autoload_subcommand_dir("cli-commands/ss")
      autoload_post_subcommand_dir("cli-commands/ss/post")
    end
    # :nocov:

    args(2...)

    run do |(ref, *argv), opts, command|
      check_no_slash(ref, "invalid secret store reference (#{ref.inspect}), should not include /", command)
      @sdk_object = sdk.secret_store.new(ref)
      command.run(self, opts, argv)
    end
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/ss")
