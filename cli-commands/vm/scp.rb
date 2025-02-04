# frozen_string_literal: true

UbiRodish.on("vm", "scp") do
  options("ubi vm scp [options] location-name (vm-name|_vm-ubid) (local-path :remote-path|:remote-path local-path)", key: :vm_ssh, &UbiCli::SSHISH_OPTS)

  args(4)

  run do |location, name, path1, path2, opts|
    remote_path1 = path1[0] == ":"
    remote_path2 = path2[0] == ":"

    if remote_path1 ^ remote_path2
      handle_ssh(location, name, opts) do |user:, address:, headers:|
        address = "[#{address}]" if address.include?(":")
        remote = "#{user}@#{address}"

        if remote_path1
          cmd_arg = "#{remote}#{path1}"
          headers["ubi-command-argv-tail"] = "1"
        else
          headers["ubi-command-argv-initial"] = "2"
          cmd_arg = "#{remote}#{path2}"
        end

        headers["ubi-command-execute"] = "scp"
        headers["ubi-command-arg"] = cmd_arg
      end
    else
      error = "Only one path should be remote (start with ':')"
      [400, {"content-type" => "text/plain", "content-length" => error.bytesize.to_s}, [error]]
    end
  end
end
