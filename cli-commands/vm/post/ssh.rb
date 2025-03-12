# frozen_string_literal: true

UbiCli.on("vm").run_on("ssh") do
  desc "Connect to a virtual machine using `ssh`"

  skip_option_parsing("ubi vm (location/vm-name | vm-id) [options] ssh [ssh-options --] [remote-cmd [remote-cmd-arg ...]]")

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
