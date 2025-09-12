# frozen_string_literal: true

Sequel.migration do
  change do
    run "UPDATE postgres_resource SET desired_version = version"
    run "UPDATE postgres_server SET version = postgres_resource.desired_version FROM postgres_resource WHERE postgres_resource.id = postgres_server.resource_id"
  end
end
