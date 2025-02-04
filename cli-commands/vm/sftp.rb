# frozen_string_literal: true

UbiRodish.on("vm", "sftp") do
  options("ubi vm sftp [options] location-name (vm-name|_vm-ubid)", key: :vm_ssh, &UbiCli::SSHISH_OPTS)

  args(2)

  run do |location, name, opts|
    handle_ssh(location, name, opts) do |user:, address:, headers:|
      address = "[#{address}]" if address.include?(":")
      headers["ubi-command-execute"] = "sftp"
      headers["ubi-command-arg"] = "#{user}@#{address}"
    end
  end
end
