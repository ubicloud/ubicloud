# frozen_string_literal: true

UbiCli.on("vm").run_on("create") do
  desc "Create a virtual machine"

  vm_sizes = Option::VmSizes.select(&:visible)
  server_sizes = vm_sizes.map(&:name).uniq.freeze
  storage_sizes = vm_sizes.map(&:storage_size_options).flatten.uniq.sort.map(&:to_s).freeze.each(&:freeze)

  options("ubi vm location/vm-name create [options] public_key", key: :vm_create) do
    on("-6", "--ipv6-only", "do not enable IPv4")
    on("-b", "--boot-image=image_name", Option::BootImages.map(&:name), "boot image")
    on("-p", "--private-subnet-id=ps-id", "place VM into specific private subnet (also accepts ps-name)")
    on("-s", "--size=size", server_sizes, "server size")
    on("-S", "--storage-size=size", storage_sizes, "storage size")
    on("-u", "--unix-user=username", "username (default: ubi)")
  end
  help_option_values("Boot Image:", Option::BootImages.map(&:name))
  help_option_values("Size:", server_sizes)
  help_option_values("Storage Size:", storage_sizes)

  help_example 'ubi vm eu-central-h1/my-vm-name create "$(cat ~/.ssh/id_ed25519.pub)"'
  help_example 'ubi vm eu-central-h1/my-vm-name create "$(cat ~/.ssh/authorized_keys)"'
  help_example "ubi vm eu-central-h1/my-vm-name create registered-ssh-public-key-name"

  args 1

  run do |public_key, opts, command|
    params = underscore_keys(opts[:vm_create])
    unless params.delete(:ipv6_only)
      params[:enable_ip4] = "1"
    end
    if params[:private_subnet_id]
      params[:private_subnet_id] = convert_name_to_id(sdk.private_subnet, params[:private_subnet_id])
    end

    params[:public_key] = public_key
    begin
      id = sdk.vm.create(location: @location, name: @name, **params).id
    rescue Ubicloud::Error => e
      if e.code == 400 && e.params.dig("error", "message").match?(/public_key invalid SSH public key format|public_key must contain at least one valid SSH public key/)
        raise Rodish::CommandFailure.new(<<~END.chomp, command)
          Invalid SSH public key provided:

          #{public_key}

          The public key given must be the name of a registered SSH public key,
          or must be a valid SSH public key
        END
      end

      raise
    end
    response("VM created with id: #{id}")
  end
end
