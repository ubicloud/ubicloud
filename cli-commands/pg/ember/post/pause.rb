# frozen_string_literal: true

class UbiCli
  on("pg", "ember").run_on("pause") do
    desc "Pause a PostgreSQL ember"

    banner "ubi pg ember (ember-name | ember-id) pause"

    run do
      # Pausing is scheduled rather than immediate, and connecting undoes it.
      id = @sdk_object.pause.id
      response("Scheduled pause of PostgreSQL ember with id: #{id}")
    end
  end
end
