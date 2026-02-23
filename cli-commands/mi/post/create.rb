# frozen_string_literal: true

UbiCli.on("mi").run_on("create") do
  desc "Create a machine image from a stopped VM"

  options("ubi mi location/mi-name create [options]", key: :mi_create) do
    on("-v", "--vm-id=vm-id", "UBID of the source VM (required)")
    on("-d", "--description=desc", "description for machine image")
  end

  run do |opts, cmd|
    params = underscore_keys(opts[:mi_create])
    unless params[:vm_id]
      raise Rodish::CommandFailure.new("vm-id is required, provide with -v option", cmd)
    end
    id = sdk.machine_image.create(location: @location, name: @name, **params).id
    response("Machine image created with id: #{id}")
  end
end
