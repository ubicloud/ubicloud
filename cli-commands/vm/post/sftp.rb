# frozen_string_literal: true

UbiRodish.on("vm").run_on("sftp") do
  options("ubi vm location-name (vm-name|_vm-ubid) sftp [options] [-- sftp-options]", key: :vm_ssh, &UbiCli::SSHISH_OPTS)

  args(0...)

  run do |argv, opts|
    handle_ssh(opts) do |user:, address:|
      address = "[#{address}]" if address.include?(":")
      ["sftp", *argv, "--", "#{user}@#{address}"]
    end
  end
end
