# frozen_string_literal: true

UbiCli.on("mi").run_on("destroy-version") do
  desc "Destroy a non-latest version of a machine image"

  options("ubi mi (location/mi-name | mi-id) destroy-version [options]", key: :mi_destroy_version) do
    on("-V", "--version=version", "version label to destroy (required)")
    on("-f", "--force", "do not require confirmation")
  end

  help_example "ubi mi eu-central-h1/my-image destroy-version -V v1.0"

  run do |opts, command|
    params = underscore_keys(opts[:mi_destroy_version])
    unless params[:version]
      raise Rodish::CommandFailure.new("--version option is required", command)
    end

    if params[:force] || opts[:confirm] == params[:version]
      sdk_object.destroy_version(params[:version])
      response("Machine image version #{params[:version]} is now scheduled for destruction")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of machine image version label not successful.
      END
    else
      require_confirmation("Confirmation", <<~END)
        Destroying this machine image version is not recoverable.
        Enter the following to confirm destruction of the machine image version: #{params[:version]}
      END
    end
  end
end
