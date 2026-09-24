# frozen_string_literal: true

class UbiCli
  # Embers are the other kind of PostgreSQL database, so they live under pg
  # rather than as a command of their own. Unlike a dedicated database, an ember
  # is addressed by name or id alone: where it lives is a create-time detail
  # rather than part of its identity.
  on("pg", "ember") do
    desc "Manage PostgreSQL embers"

    banner "ubi pg ember command [...]"
    post_banner "ubi pg ember (ember-name | ember-id) post-command [...]"

    # simplecov:disable
    unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
      autoload_subcommand_dir("cli-commands/pg/ember")
      autoload_post_subcommand_dir("cli-commands/pg/ember/post")
    end
    # simplecov:enable

    args(2...)

    run do |(ref, *argv), opts, command|
      check_no_slash(ref, "invalid ember reference (#{ref.inspect}), should not include /", command)
      @sdk_object = sdk.postgres.ember(ref)
      command.run(self, opts, argv)
    end
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/pg/ember")
