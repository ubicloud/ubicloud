# frozen_string_literal: true

class UbiCli
  on("pg", "ember").run_on("create") do
    desc "Create a PostgreSQL ember"

    options("ubi pg ember ember-name create [options]", key: :pg_ember_create) do
      on("-l", "--location=location", "location to create the ember in")
      on("-v", "--version=version", "PostgreSQL version")
      on("-d", "--dbname=name", "name of the database to create")
    end

    help_example "ubi pg ember my-db create"

    run do |opts|
      params = opts[:pg_ember_create] || {}
      ember = sdk.postgres.create_ember(
        name: @sdk_object.name,
        location: params[:location],
        pg_version: params[:version],
        database: params[:dbname],
      )
      response("PostgreSQL ember created with id: #{ember.id}\n#{ember.connection_string}")
    end
  end
end
