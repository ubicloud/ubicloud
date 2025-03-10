# frozen_string_literal: true

UbiCli.on("help") do
  desc "Get program help"

  options("ubi help [options] [command [subcommand]]") do
    on("-r", "--recursive", "also show documentation for all subcommands of command")
    on("-u", "--usage", "only show usage")
  end

  args(0..)

  run do |argv, opts|
    orig_command = command = UbiCli.command

    argv.each do |arg|
      break unless (command = command.subcommand(arg) || command.post_subcommand(arg))
      orig_command = command
    end

    usage = opts[:usage]
    if command
      if opts[:recursive]
        body = []
        command.each_subcommand do |_, cmd|
          if usage
            cmd.each_banner do |banner|
              body << banner << "\n"
            end
          else
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
        response(command.help)
      end
    else
      orig_command.raise_failure("invalid command: #{argv.join(" ")}")
    end
  end
end
