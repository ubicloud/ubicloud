# frozen_string_literal: true

UbiCli.on("ai", "api-key").run_on("destroy") do
  desc "Destroy an inference API key"

  options("ubi ai api-key api-key-id destroy [options]", key: :destroy) do
    on("-f", "--force", "do not require confirmation")
  end

  run do |opts|
    if opts.dig(:destroy, :force) || opts[:confirm] == @sdk_object.id[2, 6]
      @sdk_object.destroy
      response("Inference API key, if it exists, has been destroyed")
    elsif opts[:confirm]
      invalid_confirmation <<~END
        ! Confirmation of destruction not successful
      END
    else
      require_confirmation("Confirmation", <<~END)
        Destroying this inference API key is not recoverable.
        Enter the following to confirm destruction of the inference API key: #{@sdk_object.id[2, 6]}
      END
    end
  end
end
