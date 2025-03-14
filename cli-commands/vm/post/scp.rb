# frozen_string_literal: true

UbiCli.on("vm").run_on("scp") do
  desc "Copy files to or from virtual machine using `scp`"

  skip_option_parsing("ubi vm (location/vm-name | vm-id) [options] scp [scp-options] (local-path :remote-path | :remote-path local-path)")

  args(2...)

  run do |(*argv, path1, path2), opts|
    remote_path1 = path1[0] == ":"
    remote_path2 = path2[0] == ":"

    if remote_path1 ^ remote_path2
      handle_ssh(opts) do |user:, address:|
        address = "[#{address}]" if address.include?(":")
        remote = "#{user}@#{address}"

        if remote_path1
          path1 = "#{remote}#{path1}"
        else
          path2 = "#{remote}#{path2}"
        end

        ["scp", *argv, "--", path1, path2]
      end
    else
      error = "! Only one path should be remote (start with ':')\n"
      [400, {"content-type" => "text/plain", "content-length" => error.bytesize.to_s}, [error]]
    end
  end
end
