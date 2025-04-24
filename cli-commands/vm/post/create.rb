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

  help_example "ubi vm eu-central-h1/my-vm-name create \"$(cat ~/.ssh/id_ed25519.pub)\""
  help_example "ubi vm eu-central-h1/my-vm-name create \"$(cat ~/.ssh/authorized_keys)\""

  args 1

  run do |public_key, opts, command|
    params = underscore_keys(opts[:vm_create])
    unless params.delete(:ipv6_only)
      params[:enable_ip4] = "1"
    end

    unless Vm::VALID_SSH_AUTHORIZED_KEYS.match?(public_key)
      command.raise_failure("public key provided is not in authorized_keys format")
    end

    unless Vm::VALID_SSH_PUBLIC_KEY_LINE.match?(public_key)
      command.raise_failure("public key provided does not contain a valid public key")
    end

    params[:public_key] = public_key
    id = sdk.vm.create(location: @location, name: @name, **params).id
    response("VM created with id: #{id}")
  end
end
