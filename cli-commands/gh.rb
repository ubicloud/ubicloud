# frozen_string_literal: true

UbiCli.on("gh") do
  desc "Manage GitHub integration"

  banner "ubi gh command [...]"
  post_banner "ubi gh (installation-name/repository-name) post-command [...]"

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/gh")
    autoload_post_subcommand_dir("cli-commands/gh/post")
  end
  # :nocov:

  args(2...)

  run do |(ref, *argv), opts, command|
    if command.post_subcommand(ref)
      # support swapped reference and post command arguments
      argv.insert(1, ref)
      ref = argv.shift
    end

    installation_name, name, extra = ref.split("/", 3)

    if extra || !name
      raise Rodish::CommandFailure.new("invalid gh reference (#{ref.inspect}), should be in installation-name/repository-name format", command)
    end

    @repository = sdk.github_repository.new(installation_name:, name:)
    command.run(self, opts, argv)
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/gh")
