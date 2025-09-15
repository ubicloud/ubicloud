# frozen_string_literal: true

UbiCli.on("sk").run_on("destroy") do
  desc "Destroy an SSH public key"

  options("ubi sk (sk-name | sk-id) destroy [options]", key: :destroy) do
    on("-f", "--force", "do not require confirmation")
  end

  run do |opts|
    if opts.dig(:destroy, :force) || opts[:confirm] == @sdk_object.name
      @sdk_object.destroy
      response("SSH public key has been removed")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of SSH public key name not successful.
      END
    else
      require_confirmation("Confirmation", <<~END)
        Destroying this SSH public key is not recoverable.
        Enter the following to confirm destruction of the SSH public key: #{@sdk_object.name}
      END
    end
  end
end
