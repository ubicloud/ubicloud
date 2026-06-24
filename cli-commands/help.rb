# frozen_string_literal: true

class UbiCli
  on("help") do
    desc "Get command help"

    options("ubi help [options] [command [subcommand]]") do
      on("-r", "--recursive", "also show documentation for all subcommands of command")
      on("-u", "--usage", "only show usage")
    end

    args(0..)

    interactive_commands = [%w[vm ssh], %w[pg psql]].freeze.each(&:freeze)

    run do |argv, opts|
      orig_command = command = UbiCli.command

      argv.each do |arg|
        break unless (command = command.subcommand(arg) || command.post_subcommand(arg))

        orig_command = command
      end

      usage = opts[:usage]
      if command
        if opts[:recursive]
          skip_interactive_commands = comparable_client_version < MIN_PGPASSWORD_VERSION
          body = []
          command.each_subcommand do |_, cmd|
            next if skip_interactive_commands && interactive_commands.include?(cmd.command_path)

            if usage
              cmd.each_banner do |banner|
                body << banner << "\n"
              end
            else
              # When we want to switch to context-sensitive help
              # body << cmd.context_help(self) << "\n\n"
              body << cmd.help << "\n\n"
            end
          end
          response(body)
        elsif usage
          body = []
          command.each_banner do |banner|
            body << banner << "\n"
          end
          response(body)
        else
          # When we want to switch to context-sensitive help
          # response(command.context_help(self))
          response(command.help)
        end
      else
        orig_command.raise_failure("invalid command: #{argv.join(" ")}")
      end
    end
  end
end
