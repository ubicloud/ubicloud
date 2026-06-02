# frozen_string_literal: true

UbiCli.on("jw").run_on("destroy") do
  desc "Destroy a JWT issuer"

  options("ubi jw jw-id destroy [options]", key: :destroy) do
    on("-f", "--force", "do not require confirmation")
  end

  run do |opts|
    if opts.dig(:destroy, :force) || opts[:confirm] == @sdk_object.name
      @sdk_object.destroy
      response("JWT issuer has been removed")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of JWT issuer name not successful.
      END
    else
      require_confirmation("Confirmation", <<~END)
        Destroying this JWT issuer is not recoverable.
        Enter the name of the JWT issuer to confirm: #{@sdk_object.name}
      END
    end
  end
end
