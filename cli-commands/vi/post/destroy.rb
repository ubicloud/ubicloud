# frozen_string_literal: true

UbiCli.on("vi").run_on("destroy") do
  desc "Destroy a virtual machine init script"

  options("ubi vi (vi-name | vi-id) destroy [options]", key: :destroy) do
    on("-f", "--force", "do not require confirmation")
  end

  run do |opts|
    if opts.dig(:destroy, :force) || opts[:confirm] == @sdk_object.name
      @sdk_object.destroy
      response("Virtual machine init script has been removed")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of virtual machine init script name not successful.
      END
    else
      require_confirmation("Confirmation", <<~END)
        Destroying this virtual machine init script is not recoverable.
        Enter the following to confirm destruction of the virtual machine init script: #{@sdk_object.name}
      END
    end
  end
end
