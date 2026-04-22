# frozen_string_literal: true

UbiCli.on("mi").run_on("create-version") do
  desc "Create a new version of a machine image from a stopped VM"

  options("ubi mi (location/mi-name | mi-id) create-version [options]", key: :mi_create_version) do
    on("-v", "--vm=vm-id", "UBID of a stopped VM to capture (required)")
    on("-V", "--version=version", "version label (default: timestamp)")
    on("-d", "--destroy-source", "destroy the source VM after capture")
  end

  help_example "ubi mi eu-central-h1/my-image create-version -v vmabcdef01234567890abcdef"
  help_example "ubi mi eu-central-h1/my-image create-version -v vmabcdef01234567890abcdef -V v2.0"

  run do |opts, command|
    params = underscore_keys(opts[:mi_create_version])
    unless params[:vm]
      raise Rodish::CommandFailure.new("--vm option is required", command)
    end

    version = params[:version] || Time.now.strftime("%Y%m%d%H%M%S")
    result = sdk_object.create_version(version, vm: params[:vm], destroy_source: params[:destroy_source])
    response("Machine image version created with id: #{result.id}")
  end
end
