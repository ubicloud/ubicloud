# frozen_string_literal: true

UbiCli.on("gh", "installation") do
  desc "Manage GitHub installations"

  banner "ubi gh installation command [...]"
  post_banner "ubi gh installation installation-name post-command [...]"

  # :nocov:
  unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    autoload_subcommand_dir("cli-commands/gh/installation")
    autoload_post_subcommand_dir("cli-commands/gh/installation/post")
  end
  # :nocov:

  args(2...)

  run do |(ref, *argv), opts, command|
    check_no_slash(ref, "invalid GitHub installation reference (#{ref.inspect}), should not include /", command)
    @installation = sdk.github_installation.new(ref)
    command.run(self, opts, argv)
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/gh/installation")
