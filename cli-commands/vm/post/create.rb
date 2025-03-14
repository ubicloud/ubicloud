# frozen_string_literal: true

UbiCli.on("vm").run_on("create") do
  desc "Create a virtual machine"

  options("ubi vm location/vm-name create [options] public_key", key: :vm_create) do
    on("-6", "--ipv6-only", "do not enable IPv4")
    on("-b", "--boot-image=image_name", "boot image")
    on("-p", "--private-subnet-id=id", "place VM into specific private subnet")
    on("-s", "--size=size", "server size")
    on("-S", "--storage-size=size", "storage size")
    on("-u", "--unix-user=username", "username (default: ubi)")
  end
  vm_sizes = Option::VmSizes.select(&:visible)
  help_option_values("Boot Image:", Option::BootImages.map(&:name))
  help_option_values("Size:", vm_sizes.map(&:name).uniq)
  help_option_values("Storage Size:", vm_sizes.map(&:storage_size_options).flatten.uniq.sort)

  args 1

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
