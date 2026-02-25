# frozen_string_literal: true

UbiCli.on("mi").run_on("create") do
  desc "Create a machine image from a stopped VM"

  options("ubi mi location/mi-name create [options]", key: :mi_create) do
    on("-d", "--description=desc", "description for machine image")
    on("-v", "--vm-id=vm-id", "UBID of the source VM (must be stopped)")
  end

  run do |opts|
    params = underscore_keys(opts[:mi_create])
    id = sdk.machine_image.create(location: @location, name: @name, **params).id
    response("Machine image created with id: #{id}")
  end
end
