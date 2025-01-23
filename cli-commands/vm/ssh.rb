# frozen_string_literal: true

UbiRodish.on("vm", "ssh") do
  options("ubi vm ssh [options] location-name (vm-name|_vm-ubid) [cmd [arg, ...]]", key: :vm_ssh) do
    on("-4", "--ip4", "use IPv4 address")
    on("-6", "--ip6", "use IPv6 address")
    on("-u", "--user user", "override username")
  end

  args(2...)

  run do |argv, opts|
    location = argv.shift
    name = argv.shift
    get(project_path("location/#{location}/vm/#{name}")) do |data, res|
      if (opts = opts[:vm_ssh])
        user = opts[:user]
        if opts[:ip4]
          address = data["ip4"] || false
        elsif opts[:ip6]
          address = data["ip6"]
        end
      end

      if address.nil?
        address = if ipv6_request?
          data["ip6"] || data["ip4"]
        else
          data["ip4"] || data["ip6"]
        end
      end

      if address
        headers = res[1]
        headers["ubi-command-execute"] = "ssh"
        headers["ubi-command-arg"] = "#{user || data["unix_user"]}@#{address}"
        headers["ubi-command-argv-tail"] = argv.length.to_s
        [""]
      else
        res[0] = 400
        ["No valid IPv4 address for requested VM"]
      end
    end
  end
end
