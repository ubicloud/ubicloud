# frozen_string_literal: true

UbiCli.on("jw").run_on("destroy") do
  desc "Destroy a trusted JWT issuer"

  options("ubi jw jw-id destroy [options]", key: :destroy) do
    on("-f", "--force", "do not require confirmation")
  end

  run do |opts|
    if opts.dig(:destroy, :force) || opts[:confirm] == @sdk_object.name
      @sdk_object.destroy
      response("Trusted JWT issuer has been removed")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of trusted JWT issuer name not successful.
      END
    else
      require_confirmation("Confirmation", <<~END)
        Destroying this trusted JWT issuer is not recoverable.
        Enter the name of the trusted JWT issuer to confirm: #{@sdk_object.name}
      END
    end
  end
end
