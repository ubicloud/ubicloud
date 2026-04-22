# frozen_string_literal: true

UbiCli.on("mi").run_on("destroy-version") do
  desc "Destroy a non-latest version of a machine image"

  options("ubi mi (location/mi-name | mi-id) destroy-version [options] version", key: :mi_destroy_version) do
    on("-f", "--force", "do not require confirmation")
  end

  args 1

  run do |version, opts|
    params = opts[:mi_destroy_version]
    if params[:force] || opts[:confirm] == version
      sdk_object.destroy_version(version)
      response("Machine image version #{version} is now scheduled for destruction")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of machine image version label not successful.
      END
    else
      require_confirmation("Confirmation", <<~END)
        Destroying this machine image version is not recoverable.
        Enter the following to confirm destruction of the machine image version: #{version}
      END
    end
  end
end
