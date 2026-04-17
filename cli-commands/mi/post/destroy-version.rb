# frozen_string_literal: true

UbiCli.on("mi").run_on("destroy-version") do
  desc "Destroy a specific version of a machine image"

  options("ubi mi (location/mi-name | mi-id) destroy-version [options]", key: :mi_destroy_version) do
    on("-V", "--version=version", "version label to destroy (required)")
  end

  help_example "ubi mi eu-central-h1/my-image destroy-version -V v1.0"

  run do |opts, command|
    params = underscore_keys(opts[:mi_destroy_version])
    unless params[:version]
      raise Rodish::CommandFailure.new("--version option is required", command)
    end

    sdk_object.destroy_version(params[:version])
    response("Machine image version #{params[:version]} is now scheduled for destruction")
  end
end
