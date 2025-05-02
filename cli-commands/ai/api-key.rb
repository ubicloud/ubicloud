# frozen_string_literal: true

UbiCli.on("ai", "api-key") do
  desc "Manage AI inference API keys"

  banner "ubi ai api-key [command] ..."
  post_banner "ubi ai api-key api-key-id [post-command] ..."

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/ai/api-key")
    autoload_post_subcommand_dir("cli-commands/ai/api-key/post")
  end
  # :nocov:

  args(1...)

  run do |(id, *argv), opts, command|
    unless /\Aak[a-z0-9]{24}\z/.match?(id)
      raise Rodish::CommandFailure, "no inference API key with id #{id} exists"
    end

    @sdk_object = sdk[id]

    command.run(self, opts, argv)
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/ai/api-key")
