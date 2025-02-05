# frozen_string_literal: true

UbiRodish.on("vm", "sftp") do
  options("ubi vm sftp [options] location-name (vm-name|_vm-ubid) [sftp-options]", key: :vm_ssh, &UbiCli::SSHISH_OPTS)

  args(2...)

  run do |(location, name, *argv), opts|
    handle_ssh(location, name, opts) do |user:, address:|
      address = "[#{address}]" if address.include?(":")
      ["sftp", *argv, "--", "#{user}@#{address}"]
    end
  end
end
