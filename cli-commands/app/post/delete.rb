# frozen_string_literal: true

UbiCli.on("app").run_on("delete") do
  desc "Delete an app process (VMs are preserved)"

  options("ubi app (location/app-name | app-id) delete [options]", key: :delete) do
    on("-f", "--force", "do not require confirmation")
  end

  run do |opts|
    if opts.dig(:delete, :force) || opts[:confirm] == @name
      sdk_object.destroy
      response("App process #{@name} deleted (VMs preserved)")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of app process name not successful.
      END
    else
      require_confirmation("Confirmation", <<~END)
        Deleting this app process removes the grouping and release tracking.
        VMs, subnets, and load balancers are preserved as standalone resources.
        Enter the following to confirm deletion of the app process: #{@name}
      END
    end
  end
end
