# frozen_string_literal: true

UbiCli.on("mi").run_on("create") do
  desc "Create a machine image from a stopped VM"

  options("ubi mi location/mi-name create [options] (vm-name | vm-id)", key: :mi_create) do
    on("-V", "--version=version", "version label (default: timestamp)")
    on("-d", "--destroy-source", "destroy the source VM after capture")
  end

  args 1

  run do |vm_ref, opts|
    params = underscore_keys(opts[:mi_create])
    body = {vm: convert_name_to_id(sdk.vm, vm_ref)}
    body[:version] = params[:version] if params[:version]
    body[:destroy_source] = true if params[:destroy_source]

    result = sdk.machine_image.create(location: @location, name: @name, **body)
    response("Machine image created with id: #{result.id}")
  end
end
