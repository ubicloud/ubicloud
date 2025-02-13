# frozen_string_literal: true

UbiRodish.on("help") do
  options("ubi help [options] [command [subcommand]]") do
    on("-r", "--recursive", "also show documentation for all subcommands of command")
    on("-u", "--usage", "only show usage")
  end

  args(0..)

  run do |argv, opts|
    orig_command = command = UbiRodish.command

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
            cmd.option_parsers.each do |op|
              body << op.banner << "\n"
            end
          else
            body << cmd.options_text << "\n\n"
          end
        end
        response(body)
      elsif usage
        body = []
        command.option_parsers.each do |op|
          body << op.banner << "\n"
        end
        response(body)
      else
        response(command.options_text)
      end
    else
      orig_command.raise_failure("invalid command: #{argv.join(" ")}")
    end
  end
end
