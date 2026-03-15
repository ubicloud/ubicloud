#!/bin/bash
# Creates the default Ubicloud project with private_locations enabled
# and sets POSTGRES_SERVICE_PROJECT_ID in .env.rb.
#
# Usage: register-pg-project.sh

set -e

echo "=== Creating default project ==="

RACK_ENV=development bundle exec ruby -r ./loader -e '
  project = Project.first(name: "default")
  if project
    puts "Project \"default\" already exists (id: #{project.id})"
  else
    project = Project.create(name: "default", feature_flags: {"private_locations" => true})
    puts "Created project \"default\" (id: #{project.id})"
  end
  project.set_ff_private_locations(true)
  puts "Feature flag private_locations: #{project.get_ff_private_locations}"

  # Add POSTGRES_SERVICE_PROJECT_ID to .env.rb
  env_rb = ".env.rb"
  env_line = "ENV[\"POSTGRES_SERVICE_PROJECT_ID\"] = \"#{project.id}\""
  content = File.exist?(env_rb) ? File.read(env_rb) : ""
  if content.include?("POSTGRES_SERVICE_PROJECT_ID")
    content.gsub!(/^ENV\["POSTGRES_SERVICE_PROJECT_ID"\].*$/, env_line)
    File.write(env_rb, content)
    puts "Updated POSTGRES_SERVICE_PROJECT_ID in .env.rb"
  else
    File.open(env_rb, "a") { |f| f.puts env_line }
    puts "Added POSTGRES_SERVICE_PROJECT_ID to .env.rb"
  end
'
