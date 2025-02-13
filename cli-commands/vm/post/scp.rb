# frozen_string_literal: true

UbiRodish.on("vm").run_on("scp") do
  skip_option_parsing("ubi vm location-name/(vm-name|_vm-ubid) [options] scp [scp-opts] (local-path :remote-path | :remote-path local-path)")

  args(2..., invalid_args_message: "must provide 2 paths: either 'local-path :remote-path' or ':remote-path local-path'")

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
      error = "Only one path should be remote (start with ':')"
      [400, {"content-type" => "text/plain", "content-length" => error.bytesize.to_s}, [error]]
    end
  end
end
