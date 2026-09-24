# frozen_string_literal: true

class UbiCli
  on("pg", "ember").run_on("destroy") do
    desc "Destroy a PostgreSQL ember"

    options("ubi pg ember (ember-name | ember-id) destroy [options]", key: :destroy) do
      on("-f", "--force", "do not require confirmation")
    end

    run do |opts|
      if opts.dig(:destroy, :force) || opts[:confirm] == @sdk_object.name
        @sdk_object.destroy
        response("PostgreSQL ember, if it exists, is now scheduled for destruction")
      elsif opts[:confirm]
        invalid_confirmation <<~END
          ! Confirmation of PostgreSQL ember name not successful.
        END
      else
        require_confirmation("Confirmation", <<~END)
          Destroying this PostgreSQL ember is not recoverable.
          Enter the following to confirm destruction of the PostgreSQL ember: #{@sdk_object.name}
        END
      end
    end
  end
end
