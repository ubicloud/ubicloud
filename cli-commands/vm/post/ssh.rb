# frozen_string_literal: true

UbiRodish.on("vm").run_on("ssh") do
  skip_option_parsing

  args(0...)

  run do |argv, opts|
    handle_ssh(opts) do |user:, address:|
      if (i = argv.index("--"))
        options = argv[0...i]
        argv = argv[(i + 1)...]
      end

      ["ssh", *options, "--", "#{user}@#{address}", *argv]
    end
  end
end
