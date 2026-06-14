# frozen_string_literal: true

class UbiCli
  on("ss").run_on("destroy") do
    desc "Destroy a secret store"

    options("ubi ss (ss-name | ss-id) destroy [options]", key: :destroy) do
      on("-f", "--force", "do not require confirmation")
    end

    run do |opts|
      if opts.dig(:destroy, :force) || opts[:confirm] == @sdk_object.name
        @sdk_object.destroy
        response("Secret store, and all secrets it contains, have been destroyed")
      elsif opts[:confirm]
        invalid_confirmation <<~END
          ! Confirmation of secret store name not successful.
        END
      else
        require_confirmation("Confirmation", <<~END)
          Destroying this secret store is not recoverable.
          Enter the following to confirm destruction of the secret store: #{@sdk_object.name}
        END
      end
    end
  end
end
