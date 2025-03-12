# frozen_string_literal: true

UbiCli.on("vm").run_on("sftp") do
  desc "Copy files to or from virtual machine using `sftp`"

  skip_option_parsing("ubi vm (location/vm-name | vm-id) [options] sftp [sftp-options]")

  args(0...)

  run do |argv, opts|
    handle_ssh(opts) do |user:, address:|
      address = "[#{address}]" if address.include?(":")
      ["sftp", *argv, "--", "#{user}@#{address}"]
    end
  end
end
