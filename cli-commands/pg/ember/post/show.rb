# frozen_string_literal: true

class UbiCli
  on("pg", "ember").run_on("show") do
    desc "Show details for a PostgreSQL ember"

    banner "ubi pg ember (ember-name | ember-id) show"

    run do
      ember = @sdk_object
      response([
        "id: ", ember.id, "\n",
        "name: ", ember.name, "\n",
        "location: ", ember.location, "\n",
        "state: ", ember.state, "\n",
        "version: ", ember.pg_version, "\n",
        "database: ", ember.database, "\n",
        "connection string: ", ember.connection_string, "\n",
      ])
    end
  end
end
