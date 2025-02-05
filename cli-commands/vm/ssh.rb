# frozen_string_literal: true

UbiRodish.on("vm", "ssh") do
  options("ubi vm ssh [options] location-name (vm-name|_vm-ubid) [ssh-options --] [cmd [arg, ...]]", key: :vm_ssh, &UbiCli::SSHISH_OPTS)

  args(2...)

  run do |(location, name, *argv), opts|
    handle_ssh(location, name, opts) do |user:, address:|
      if (i = argv.index("--"))
        options = argv[0...i]
        argv = argv[(i + 1)...]
      end

      ["ssh", *options, "--", "#{user}@#{address}", *argv]
    end
  end
end
