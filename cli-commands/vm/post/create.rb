# frozen_string_literal: true

UbiCli.on("vm").run_on("create") do
  options("ubi vm location/vm_name create [options] public_key", key: :vm_create) do
    on("-6", "--ipv6-only", "do not enable IPv4")
    on("-b", "--boot-image=image_name", "boot image (ubuntu-noble,ubuntu-jammy,debian-12,almalinux-9)")
    on("-p", "--private-subnet-id=id", "place VM into specific private subnet")
    on("-s", "--size=size", "server size (standard-{2,4,8,16,30,60})")
    on("-S", "--storage-size=size", "storage size (40, 80)")
    on("-u", "--unix-user=username", "username (default: ubi)")
  end

  args(1, invalid_args_message: "public_key is required")

  run do |public_key, opts|
    params = underscore_keys(opts[:vm_create])
    unless params.delete("ipv6_only")
      params["enable_ip4"] = "1"
    end
    params["public_key"] = public_key.gsub(/(?!\r)\n/, "\r\n")
    post(vm_path, params) do |data|
      ["VM created with id: #{data["id"]}"]
    end
  end
end
