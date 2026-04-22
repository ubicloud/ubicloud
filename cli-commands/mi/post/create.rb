# frozen_string_literal: true

UbiCli.on("mi").run_on("create") do
  desc "Create a machine image from a stopped VM"

  options("ubi mi location/mi-name create [options]", key: :mi_create) do
    on("-v", "--vm=vm-id", "UBID of a stopped VM to capture (required)")
    on("-V", "--version=version", "version label (default: timestamp)")
    on("-d", "--destroy-source", "destroy the source VM after capture")
  end

  help_example "ubi mi eu-central-h1/my-image create -v vmabcdef01234567890abcdef"
  help_example "ubi mi eu-central-h1/my-image create -v vmabcdef01234567890abcdef -V v1.0"

  run do |opts, command|
    params = underscore_keys(opts[:mi_create])
    unless params[:vm]
      raise Rodish::CommandFailure.new("--vm option is required", command)
    end

    body = {vm: params[:vm]}
    body[:version] = params[:version] if params[:version]
    body[:destroy_source] = true if params[:destroy_source]

    result = sdk.machine_image.create(location: @location, name: @name, **body)
    response("Machine image created with id: #{result.id}")
  end
end
