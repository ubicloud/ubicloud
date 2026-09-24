# frozen_string_literal: true

class UbiCli
  on("pg", "ember").run_on("reset-password") do
    desc "Reset the superuser password for a PostgreSQL ember"

    banner "ubi pg ember (ember-name | ember-id) reset-password"

    run do
      # The new password is generated for you: there is one role in an ember and
      # nothing else to coordinate it with.
      ember = @sdk_object.reset_password
      response(["password: ", ember.password, "\n"])
    end
  end
end
