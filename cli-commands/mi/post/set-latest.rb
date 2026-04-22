# frozen_string_literal: true

UbiCli.on("mi").run_on("set-latest") do
  desc "Set the latest version of a machine image (or unset it)"

  options("ubi mi (location/mi-name | mi-id) set-latest [options]", key: :mi_set_latest) do
    on("-V", "--version=version", "version label to make latest")
    on("-u", "--unset", "unset the latest version")
  end

  help_example "ubi mi eu-central-h1/my-image set-latest -V v2"
  help_example "ubi mi eu-central-h1/my-image set-latest --unset"

  run do |opts, command|
    params = underscore_keys(opts[:mi_set_latest])
    if params[:version] && params[:unset]
      raise Rodish::CommandFailure.new("--version and --unset are mutually exclusive", command)
    end
    unless params[:version] || params[:unset]
      raise Rodish::CommandFailure.new("--version or --unset is required", command)
    end

    sdk_object.set_latest_version(params[:unset] ? nil : params[:version])
    response(params[:unset] ? "Machine image latest version unset" : "Machine image latest version set to #{params[:version]}")
  end
end
