# frozen_string_literal: true

class UbiCli
  on("pg", "ember").run_on("resume") do
    desc "Resume a paused PostgreSQL ember"

    banner "ubi pg ember (ember-name | ember-id) resume"

    run do
      ember = @sdk_object.resume
      response("PostgreSQL ember with id #{ember.id} is #{ember.state}")
    end
  end
end
