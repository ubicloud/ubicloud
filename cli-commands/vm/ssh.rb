# frozen_string_literal: true

UbiRodish.on("vm", "ssh") do
  options("ubi vm ssh [options] location-name (vm-name|_vm-ubid) [cmd [arg, ...]]", key: :vm_ssh, &UbiCli::SSHISH_OPTS)

  args(2...)

  run do |argv, opts|
    handle_ssh(argv.shift, argv.shift, opts) do |user:, address:, headers:|
      headers["ubi-command-execute"] = "ssh"
      headers["ubi-command-arg"] = "#{user}@#{address}"
      headers["ubi-command-argv-tail"] = argv.length.to_s
    end
  end
end
